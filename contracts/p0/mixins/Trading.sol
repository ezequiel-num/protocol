// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../interfaces/IBroker.sol";
import "../../interfaces/IMain.sol";
import "../../interfaces/ITrade.sol";
import "../../libraries/Fixed.sol";
import "./Rewardable.sol";

/// Abstract trading mixin for all Traders, to be paired with TradingLib
abstract contract TradingP0 is RewardableP0, ITrading {
    using FixLib for uint192;
    using SafeERC20 for IERC20Metadata;

    uint192 public constant MAX_TRADE_VOLUME = 1e29; // {UoA}
    uint192 public constant MAX_TRADE_SLIPPAGE = 1e18; // {%}

    // All trades
    mapping(IERC20 => ITrade) public trades;
    uint48 public tradesOpen;

    // === Governance params ===
    uint192 public maxTradeSlippage; // {%}

    uint192 public minTradeVolume; // {UoA}

    mapping(TradeKind => uint48) public lastEndTime; // {s} block timestamp

    // untestable:
    //      `else` branch of `onlyInitializing` (ie. revert) is currently untestable.
    //      This function is only called inside other `init` functions, each of which is wrapped
    //      in an `initializer` modifier, which would fail first.
    // solhint-disable-next-line func-name-mixedcase
    function __Trading_init(uint192 maxTradeSlippage_, uint192 minTradeVolume_)
        internal
        onlyInitializing
    {
        setMaxTradeSlippage(maxTradeSlippage_);
        setMinTradeVolume(minTradeVolume_);
    }

    /// Settle a single trade, expected to be used with multicall for efficient mass settlement
    /// @param sell The sell token in the trade
    /// @return trade The ITrade contract settled
    /// @custom:interaction
    function settleTrade(IERC20 sell)
        public
        virtual
        notTradingPausedOrFrozen
        returns (ITrade trade)
    {
        trade = trades[sell];
        require(address(trade) != address(0), "no trade open");
        require(trade.canSettle(), "cannot settle yet");

        delete trades[sell];
        tradesOpen--;
        (uint256 soldAmt, uint256 boughtAmt) = trade.settle();
        emit TradeSettled(trade, trade.sell(), trade.buy(), soldAmt, boughtAmt);
    }

    /// Try to initiate a trade with a trading partner provided by the broker
    /// @param kind TradeKind.DUTCH_AUCTION or TradeKind.BATCH_AUCTION
    function tryTrade(TradeKind kind, TradeRequest memory req) internal {
        IBroker broker = main.broker();
        assert(address(trades[req.sell.erc20()]) == address(0));
        require(!broker.disabled(), "broker disabled");

        req.sell.erc20().safeApprove(address(broker), 0);
        req.sell.erc20().safeApprove(address(broker), req.sellAmount);

        // Only allow starting the next auction back-to-back if msgSender is self
        // Only time this happens is BackingManager.settleTrade() -> BackingManager.rebalance()
        // TODO is there a better way to do this?
        if (_msgSender() != address(this)) {
            // Warning, Assumption: blocktime <= 12s
            // Require at least 1 block between auctions of the same kind
            // This gives space for someone to start one of the opposite kinds of auctions
            if (kind == TradeKind.DUTCH_AUCTION) {
                require(
                    block.timestamp > lastEndTime[TradeKind.DUTCH_AUCTION] + 12,
                    "wait 1 block"
                );
            } else {
                // kind == TradeKind.BATCH_AUCTION
                require(
                    block.timestamp > lastEndTime[TradeKind.BATCH_AUCTION] + 12,
                    "wait 1 block"
                );
            }
        }

        ITrade trade = broker.openTrade(kind, req);
        uint48 endTime = trade.endTime();
        if (endTime > lastEndTime[kind]) lastEndTime[kind] = endTime;

        trades[req.sell.erc20()] = trade;
        tradesOpen++;
        emit TradeStarted(
            trade,
            req.sell.erc20(),
            req.buy.erc20(),
            req.sellAmount,
            req.minBuyAmount
        );
    }

    // === Setters ===

    /// @custom:governance
    function setMaxTradeSlippage(uint192 val) public governance {
        require(val < MAX_TRADE_SLIPPAGE, "invalid maxTradeSlippage");
        emit MaxTradeSlippageSet(maxTradeSlippage, val);
        maxTradeSlippage = val;
    }

    /// @custom:governance
    function setMinTradeVolume(uint192 val) public governance {
        require(val <= MAX_TRADE_VOLUME, "invalid minTradeVolume");
        emit MinTradeVolumeSet(minTradeVolume, val);
        minTradeVolume = val;
    }

    // === FixLib Helper ===

    /// Light wrapper around FixLib.mulDiv to support try-catch
    function mulDivCeil(
        uint192 x,
        uint192 y,
        uint192 z
    ) external pure returns (uint192) {
        return x.mulDiv(y, z, CEIL);
    }
}
