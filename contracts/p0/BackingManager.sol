// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./mixins/TradingLib.sol";
import "./mixins/Trading.sol";
import "../interfaces/IAsset.sol";
import "../interfaces/IAssetRegistry.sol";
import "../interfaces/IBroker.sol";
import "../interfaces/IMain.sol";
import "../libraries/Array.sol";
import "../libraries/Fixed.sol";

/**
 * @title BackingManager
 * @notice The backing manager holds + manages the backing for an RToken
 */
contract BackingManagerP0 is TradingP0, IBackingManager {
    using FixLib for uint192;
    using SafeERC20 for IERC20;

    uint48 public constant MAX_TRADING_DELAY = 31536000; // {s} 1 year
    uint192 public constant MAX_BACKING_BUFFER = 1e18; // {%}

    uint48 public tradingDelay; // {s} how long to wait until resuming trading after switching
    uint192 public backingBuffer; // {%} how much extra backing collateral to keep

    function init(
        IMain main_,
        uint48 tradingDelay_,
        uint192 backingBuffer_,
        uint192 maxTradeSlippage_,
        uint192 maxTradeVolume_
    ) public initializer {
        __Component_init(main_);
        __Trading_init(maxTradeSlippage_, maxTradeVolume_);
        setTradingDelay(tradingDelay_);
        setBackingBuffer(backingBuffer_);
    }

    // Give RToken max allowance over a registered token
    /// @dev Performs a uniqueness check on the erc20s list in O(n^2)
    /// @custom:interaction
    function grantRTokenAllowance(IERC20 erc20) external notFrozen {
        require(main.assetRegistry().isRegistered(erc20), "erc20 unregistered");
        erc20.safeApprove(address(main.rToken()), 0);
        erc20.safeApprove(address(main.rToken()), type(uint256).max);
    }

    /// Settle a single trade. If DUTCH_AUCTION, try rebalance()
    /// @param sell The sell token in the trade
    /// @return trade The ITrade contract settled
    /// @custom:interaction
    function settleTrade(IERC20 sell) public override(ITrading, TradingP0) returns (ITrade trade) {
        trade = super.settleTrade(sell);

        // if the settler is the trade contract itself, try chaining with another rebalance()
        if (_msgSender() == address(trade)) {
            // solhint-disable-next-line no-empty-blocks
            try this.rebalance(trade.KIND()) {} catch (bytes memory errData) {
                // prevent MEV searchers from providing less gas on purpose by reverting if OOG
                // see: docs/solidity-style.md#Catching-Empty-Data
                if (errData.length == 0) revert(); // solhint-disable-line reason-string
            }
        }
    }

    /// Apply the overall backing policy using the specified TradeKind, taking a haircut if unable
    /// @param kind TradeKind.DUTCH_AUCTION or TradeKind.BATCH_AUCTION
    /// @custom:interaction RCEI
    function rebalance(TradeKind kind) external notTradingPausedOrFrozen {
        // == Refresh ==
        main.assetRegistry().refresh();
        main.furnace().melt();

        require(tradesOpen == 0, "trade open");
        require(main.basketHandler().isReady(), "basket not ready");
        require(
            block.timestamp >= main.basketHandler().timestamp() + tradingDelay,
            "trading delayed"
        );
        require(!main.basketHandler().fullyCollateralized(), "already collateralized");

        /*
         * Recollateralization
         *
         * Strategy: iteratively move the system on a forgiving path towards collateralization
         * through a narrowing BU price band. The initial large spread reflects the
         * uncertainty associated with the market price of defaulted/volatile collateral, as
         * well as potential losses due to trading slippage. In the absence of further
         * collateral default, the size of the BU price band should decrease with each trade
         * until it is 0, at which point collateralization is restored.
         *
         * If we run out of capital and are still undercollateralized, we compromise
         * rToken.basketsNeeded to the current basket holdings. Haircut time.
         */

        BasketRange memory basketsHeld = main.basketHandler().basketsHeldBy(address(this));
        (bool doTrade, TradeRequest memory req) = TradingLibP0.prepareRecollateralizationTrade(
            this,
            basketsHeld
        );

        if (doTrade) {
            // Seize RSR if needed
            if (req.sell.erc20() == main.rsr()) {
                uint256 bal = req.sell.erc20().balanceOf(address(this));
                if (req.sellAmount > bal) main.stRSR().seizeRSR(req.sellAmount - bal);
            }

            tryTrade(kind, req);
        } else {
            // Haircut time
            compromiseBasketsNeeded(basketsHeld.bottom);
        }
    }

    /// Forward revenue to RevenueTraders; reverts if not fully collateralized
    /// @param erc20s The tokens to forward
    /// @custom:interaction RCEI
    function forwardRevenue(IERC20[] calldata erc20s) external notTradingPausedOrFrozen {
        require(ArrayLib.allUnique(erc20s), "duplicate tokens");

        // == Refresh ==
        main.assetRegistry().refresh();
        main.furnace().melt();

        require(tradesOpen == 0, "trade open");
        require(main.basketHandler().isReady(), "basket not ready");
        require(
            block.timestamp >= main.basketHandler().timestamp() + tradingDelay,
            "trading delayed"
        );
        require(main.basketHandler().fullyCollateralized(), "undercollateralized");

        BasketRange memory basketsHeld = main.basketHandler().basketsHeldBy(address(this));
        assert(main.basketHandler().status() == CollateralStatus.SOUND);

        // Special-case RSR to forward to StRSR pool
        uint256 rsrBal = main.rsr().balanceOf(address(this));
        if (rsrBal > 0) {
            main.rsr().safeTransfer(address(main.stRSR()), rsrBal);
        }

        // Mint revenue RToken
        uint192 needed; // {BU}
        {
            IRToken rToken = main.rToken();
            needed = rToken.basketsNeeded(); // {BU}
            if (basketsHeld.bottom.gt(needed)) {
                int8 decimals = int8(rToken.decimals());
                uint192 totalSupply = shiftl_toFix(rToken.totalSupply(), -decimals); // {rTok}

                // {BU} = {BU} - {BU}
                uint192 extraBUs = basketsHeld.bottom.minus(needed);

                // {qRTok: Fix} = {BU} * {qRTok / BU} (if needed == 0, conv rate is 1 qRTok/BU)
                uint192 rTok = (needed > 0) ? extraBUs.mulDiv(totalSupply, needed) : extraBUs;

                rToken.mint(address(this), rTok);
                rToken.setBasketsNeeded(basketsHeld.bottom);
            }
        }

        // Keep a small surplus of individual collateral
        needed = main.rToken().basketsNeeded().mul(FIX_ONE.plus(backingBuffer));

        // Handout excess assets above what is needed, including any newly minted RToken
        RevenueTotals memory totals = main.distributor().totals();
        for (uint256 i = 0; i < erc20s.length; i++) {
            IAsset asset = main.assetRegistry().toAsset(erc20s[i]);

            uint192 bal = asset.bal(address(this)); // {tok}
            uint192 req = needed.mul(main.basketHandler().quantity(erc20s[i]), CEIL);

            if (bal.gt(req)) {
                // delta: {qTok}
                uint256 delta = bal.minus(req).shiftl_toUint(int8(asset.erc20Decimals()));
                uint256 tokensPerShare = delta / (totals.rTokenTotal + totals.rsrTotal);

                // solhint-disable no-empty-blocks
                {
                    uint256 toRSR = tokensPerShare * totals.rsrTotal;
                    if (toRSR > 0) {
                        erc20s[i].safeTransfer(address(main.rsrTrader()), toRSR);
                        try
                            main.rsrTrader().manageToken(erc20s[i], TradeKind.DUTCH_AUCTION)
                        {} catch {}
                        // no need to revert during OOG because caller is already altruistic
                    }
                }
                {
                    uint256 toRToken = tokensPerShare * totals.rTokenTotal;
                    if (toRToken > 0) {
                        erc20s[i].safeTransfer(address(main.rTokenTrader()), toRToken);
                        try
                            main.rTokenTrader().manageToken(erc20s[i], TradeKind.DUTCH_AUCTION)
                        {} catch {}
                        // no need to revert during OOG because caller is already altruistic
                    }
                }
                // solhint-enable no-empty-blocks
            }
        }
    }

    /// Compromise on how many baskets are needed in order to recollateralize-by-accounting
    /// @param wholeBasketsHeld {BU} The number of full basket units held by the BackingManager
    function compromiseBasketsNeeded(uint192 wholeBasketsHeld) private {
        assert(tradesOpen == 0 && !main.basketHandler().fullyCollateralized());
        main.rToken().setBasketsNeeded(wholeBasketsHeld);
        assert(main.basketHandler().fullyCollateralized());
    }

    // === Setters ===

    /// @custom:governance
    function setTradingDelay(uint48 val) public governance {
        require(val <= MAX_TRADING_DELAY, "invalid tradingDelay");
        emit TradingDelaySet(tradingDelay, val);
        tradingDelay = val;
    }

    /// @custom:governance
    function setBackingBuffer(uint192 val) public governance {
        require(val <= MAX_BACKING_BUFFER, "invalid backingBuffer");
        emit BackingBufferSet(backingBuffer, val);
        backingBuffer = val;
    }
}
