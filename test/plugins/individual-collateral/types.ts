import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers'
import { BigNumberish } from 'ethers'
import { Fixture } from 'ethereum-waffle'
import { MockV3Aggregator, ICollateral, IERC20 } from '../../../typechain'

export interface CollateralFixtureContext {
  collateral: ICollateral
  chainlinkFeed: MockV3Aggregator
  tok: IERC20
  tokDecimals: number // tldr; IERC20 does not include decimals()
  rewardToken: IERC20
  alice?: SignerWithAddress
}

export interface CollateralOpts {
  erc20?: string
  targetName?: string
  rewardERC20?: string
  priceTimeout?: BigNumberish
  chainlinkFeed?: string
  oracleError?: BigNumberish
  oracleTimeout?: BigNumberish
  maxTradeVolume?: BigNumberish
  defaultThreshold?: BigNumberish
  delayUntilDefault?: BigNumberish
}

export type DeployCollateralFunc = (opts: CollateralOpts) => Promise<ICollateral>
export type MakeCollateralFixtureFunc<T extends CollateralFixtureContext> = (
  alice: SignerWithAddress,
  opts: CollateralOpts
) => Fixture<T>
export type MintCollateralFunc<T extends CollateralFixtureContext> = (
  ctx: T,
  amount: BigNumberish,
  user: SignerWithAddress,
  recipient: string
) => Promise<void>
export interface CollateralTestSuiteFixtures<T extends CollateralFixtureContext> {
  deployCollateral: DeployCollateralFunc
  collateralSpecificConstructorTests: () => void
  collateralSpecificStatusTests: () => void
  beforeEachRewardsTest: (ctx: T) => void
  makeCollateralFixtureContext: MakeCollateralFixtureFunc<T>
  mintCollateralTo: MintCollateralFunc<T>
  reduceRefPerTok: (ctx: T) => void
  itClaimsRewards: Mocha.TestFunction | Mocha.PendingTestFunction
  resetFork: () => void
  collateralName: string
}

export enum CollateralStatus {
  SOUND,
  IFFY,
  DISABLED,
}
