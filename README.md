# invariant-kit

Drop-in Foundry invariants and known-exploit checks for the DeFi primitives that
lose money while every line looks correct. Point a module at your own contract
and let Foundry fuzz the properties that actually matter — or run a coded exploit
check and get a failing transaction if the bug is present, not a vague warning.

The bugs this targets are the ones that don't revert and pass a normal test
suite: ERC-4626 share inflation, reward-accounting mistakes, AMM value leaks,
proxy storage collisions, reserves that no longer cover liabilities, value
stranded in a forwarder, orders filled twice. Each module is self-contained and
depends only on `forge-std`.

Several of these modules generalise property patterns that caught real bugs in
the author's own DeFi product line — battle-tested shapes, packaged so you point
them at your contract in a few lines.

## Install

```bash
forge install dngr2/invariant-kit
```

```toml
# foundry.toml — the invariant modules want a few runs
[invariant]
runs = 256
depth = 64
fail_on_revert = false
```

## Modules

### ERC-4626 vaults  ✅ available

Two tools for any ERC-4626 vault:

**1. Invariant harness** — extend it, hand it your vault, and Foundry fuzzes the
core accounting under random deposit/redeem/**donate** sequences (the donate
action is the inflation vector — a correct vault must survive it):

```solidity
import {ERC4626InvariantHarness, IERC4626Like, IERC20Mint} from "invariant-kit/src/modules/ERC4626Invariants.sol";

contract MyVaultInvariants is ERC4626InvariantHarness {
    function _setUpVault() internal override returns (IERC4626Like, IERC20Mint) {
        MyToken t = new MyToken();
        MyVault  v = new MyVault(t);
        return (IERC4626Like(address(v)), IERC20Mint(address(t)));
    }
}
```

Checked invariants:
- `invariant_solvency` — outstanding shares never convert to more assets than the vault holds.
- `invariant_roundTripNoValueCreation` — a deposit→redeem round trip never manufactures value (rounding favours the vault).

**2. Inflation exploit check** — runs the first-depositor / share-inflation
attack against your vault and fails with a concrete transaction if it works:

```solidity
import {ERC4626InflationCheck, IERC4626Like, IERC20Mint} from "invariant-kit/src/checks/ERC4626InflationCheck.sol";

contract MyVaultChecks is ERC4626InflationCheck {
    function test_notInflatable() public {
        MyToken t = new MyToken();
        MyVault v = new MyVault(t);
        assertNotInflatable(IERC4626Like(address(v)), IERC20Mint(address(t)));
    }
}
```

The bundled reference vaults show both outcomes: the check strands the victim on
a naive vault (no virtual shares) and clears an OZ-style vault with a decimals
offset.

```bash
forge test   # 4 passing: safe-vault invariants + inflation check on naive vs safe
```

### Staking rewards  ✅ available

The single most common real staking finding is an **unrestricted
`notifyRewardAmount`**: when anyone can call it, a griefer re-stretches the reward
period with tiny amounts and dilutes every staker's reward rate. The check flags
it:

```solidity
import {StakingNotifyCheck} from "invariant-kit/src/checks/StakingNotifyCheck.sol";

contract MyStakingChecks is StakingNotifyCheck {
    function test_notifyRestricted() public {
        assertNotifyRestricted(address(myStaking)); // fails if anyone can notify
    }
}
```

The bundled Synthetix-model reference pair shows both outcomes: the check catches
the unrestricted variant and clears the distributor-only one.

### Constant-product AMM  ✅ available

Fuzz that `reserve0 * reserve1` never decreases (the property that catches linear
quotes, missing fees, wrong rounding — any pricing that leaks LP value), plus a
round-trip drain check:

```solidity
import {ConstantProductInvariantHarness, IConstantProductAMM} from "invariant-kit/src/modules/ConstantProductInvariants.sol";

contract MyPoolInvariants is ConstantProductInvariantHarness {
    function _setUpAMM() internal override returns (IConstantProductAMM) {
        return IConstantProductAMM(address(new MyPool(reserve0, reserve1)));
    }
}
```

`AMMRoundTripCheck.assertNoRoundTripProfit` confirms a swap a→b→a never returns
more than it put in. The reference pair shows both: the linear-price pool leaks
`k` and lets a round trip profit; the fee'd constant-product pool holds.

### ERC-1967 proxy  ✅ available

The two ways upgradeable contracts get taken over:

```solidity
import {ProxyInitCheck} from "invariant-kit/src/checks/ProxyInitCheck.sol";

contract MyProxyChecks is ProxyInitCheck {
    function test_initGuarded() public {
        // ... deploy + initialize your proxy ...
        assertInitializerProtected(address(proxy)); // fails if re-initializable
    }
}
```

`assertInitializerProtected` catches an **unprotected initializer** (anyone
re-initializes and takes ownership). The reference suite also demonstrates a
**storage-collision upgrade** corrupting `owner` versus an append-only upgrade
preserving it — the pattern to check before every upgrade.

### Over-collateralised lending market  ✅ available

Fuzz an isolated or pooled lending market (Morpho-style) under random
borrow/repay/oracle/liquidate sequences — the state that produces underwater
positions and bad debt:

```solidity
import {LendingInvariantHarness, ILendingMarket, IERC20Mintable, ISettableOracle} from "invariant-kit/src/modules/LendingInvariants.sol";

contract MyMarketInvariants is LendingInvariantHarness {
    function _setUpMarket() internal override
        returns (ILendingMarket, IERC20Mintable, IERC20Mintable, ISettableOracle)
    { /* deploy + return market, loan token, collateral token, oracle */ }
}
```

Checked invariants:
- `invariant_idleLiquidityNonNegative` — `loanBalance + totalBorrowAssets >= totalSupplyAssets`. Catches **unsocialised bad debt**: a market that writes debt off the borrower but not the supply side leaves `totalSupplyAssets` overstated and goes silently insolvent.
- `invariant_neverOverLent` — `totalBorrowAssets <= totalSupplyAssets` (never lend out more than supplied).
- `invariant_noPhantomBadDebt` — a fully-liquidated (zero-collateral) borrower carries zero debt (bad debt is socialised, not left as phantom, uncollectable debt).
- `invariant_collateralBacking` — held collateral `>= totalCollateral` (tracked).

The reference pair shows both outcomes: the correct market socialises the loss and stays solvent; the broken one forgets `totalSupplyAssets -= badDebt` and trips `invariant_idleLiquidityNonNegative` after a single bad-debt liquidation.

### Profit-locking ERC-4626 allocator  ✅ available

Yearn-V3-style vault that drips reported profit into the price per share over an
unlock window. Fuzz that a gain report cannot be sandwiched:

```solidity
import {ProfitLockingInvariantHarness, IProfitLockingVault, IERC20Mint} from "invariant-kit/src/modules/ProfitLockingInvariants.sol";

contract MyAllocatorInvariants is ProfitLockingInvariantHarness {
    function _setUpVault() internal override returns (IProfitLockingVault, IERC20Mint)
    { /* deploy + return vault, asset */ }
}
```

Checked properties:
- **Anti-sandwich / PPS monotonicity** — the price per share must not move in the block a gain is reported, and never falls between actions absent a realised loss. Catches a vault that **credits profit to PPS instantly** (a front-runner deposits before the report and redeems after, stealing the gain).
- `invariant_solvency` — `convertToAssets(totalSupply()) <= totalAssets()`.
- `invariant_lockedNotExceedSelfBalance` / `invariant_selfBalanceAccounting` — locked profit shares never exceed the vault's own share balance, and `locked + unlocked == selfBalance`.

The reference pair shows both: the correct vault mints locked shares so PPS is flat in-block then unlocks linearly; the broken one credits profit instantly and jumps PPS in the report block.

### Async-redeem (ERC-7540) reserve conservation  ✅ available

A stateless conservation check for an async-redeem vault, where assets are
reserved between fulfilment and claim:

```solidity
import {AsyncRedeemConservationCheck, IAsyncRedeemVault} from "invariant-kit/src/checks/AsyncRedeemConservationCheck.sol";

contract MyVaultChecks is AsyncRedeemConservationCheck {
    function test_reserveConserved() public {
        assertReserveConserved(IAsyncRedeemVault(address(vault)), controllers);
    }
}
```

`assertReserveConserved` fails unless (1) reserved assets `<=` assets the vault
holds and (2) the per-controller claimable amounts sum to exactly
`totalReserved`. The reference pair shows both: the correct vault records the
reserve on fulfilment; the broken one drops the accounting, so 60 assets stay
claimable against a reserve of 0 — the leak the check catches.

### Reserve-backed solvency  ✅ available

The most reused property in DeFi review: a bonding curve, a savings vault, a CDP,
a prediction market and a casino bankroll all reduce to *hold at least what you
owe*. The adapter is two views — `assetBalance()` (what you hold now) and
`totalOwed()` (what you must be able to pay out now) — and Foundry fuzzes your own
actions against them:

```solidity
import {ReserveSolvencyInvariant, IReserveBacked} from "invariant-kit/src/modules/ReserveSolvencyInvariants.sol";

contract MySystemInvariants is ReserveSolvencyInvariant {
    function _setUpSystem() internal override returns (IReserveBacked, address handler) {
        MySystem s = new MySystem();
        return (IReserveBacked(address(s)), address(new MyActions(s)));
    }
}
```

`invariant_reserveCoversLiabilities` asserts `assetBalance() >= totalOwed()` after
every action. The reference pair shows both: the reserve-capped savings vault only
promises the interest its reserves cover and stays solvent; the overpromising one
credits interest it holds no reserves for, so `totalOwed` climbs past
`assetBalance` and it goes silently insolvent — the state the invariant catches.

### No-value-retained forwarder  ✅ available

For any batch / aggregator / multicall / disperse entrypoint that takes
`msg.value` and fans it out: it must end every call holding **none** of the
caller's value. The adapter is the one entrypoint; the invariant checks the
forwarder's balance is back at its baseline after every call:

```solidity
import {NoValueRetainedInvariant, IValueBatchForwarder} from "invariant-kit/src/modules/NoValueRetainedInvariants.sol";

contract MyForwarderInvariants is NoValueRetainedInvariant {
    function _setUpForwarder() internal override returns (IValueBatchForwarder) {
        return IValueBatchForwarder(address(new MyForwarder()));
    }
}
```

`invariant_noValueRetained` catches the classic stranded-ETH aggregator: the
reference pair shows a refunding forwarder that returns every unspent and
skipped-sub-call remainder (balance back to baseline) versus one that forgets the
refund, so a skipped sub-call's value sits stranded in the contract for anyone to
sweep.

### No-overfill / no-replay order settler  ✅ available

For a signed-order / OTC settlement book. The adapter exposes
`fillableRemaining(orderId)`, a `fill` action and a per-account `nonceOf` tracker;
Foundry fuzzes fills and the handler asserts every fill advances the nonce by
exactly one:

```solidity
import {NoOverfillInvariant, IOrderSettlement} from "invariant-kit/src/modules/NoOverfillInvariants.sol";

contract MyBookInvariants is NoOverfillInvariant {
    function _setUpBook() internal override returns (IOrderSettlement, bytes32[] memory ids) {
        MyBook b = new MyBook();
        /* create orders, collect their ids */
        return (IOrderSettlement(address(b)), ids);
    }
}
```

`invariant_noOverfill` asserts no order is ever filled past its size. The
reference pair shows both: the CEI settler persists `filled` before paying the
taker, so a reentrant taker's second fill trips the overfill check and the attack
reverts; the vulnerable one records `filled` *after* the transfer, so a reentrant
taker fills the same open amount twice — `filled` ends past `orderSize` (a
double-fill / replay) and the invariant catches it.

### Fee-on-transfer accounting  ✅ available

For any pool / vault / escrow that pulls a token in and credits the depositor an
internal balance. With a fee-on-transfer (or deflationary/rebasing) token, fewer
tokens arrive than were requested, so a contract that credits the *requested*
amount promises more than it holds:

```solidity
import {FeeOnTransferInvariant, IFeeAware} from "invariant-kit/src/modules/FeeOnTransferInvariants.sol";

contract MyPoolInvariants is FeeOnTransferInvariant {
    function _setUpSystem() internal override returns (IFeeAware, address handler) {
        MyPool p = new MyPool(/* a fee-on-transfer token */);
        return (IFeeAware(address(p)), address(new MyActions(p)));
    }
}
```

`invariant_creditBackedByBalance` asserts `creditedTotal <= tokenBalance`. The
reference pair drives a 1%-fee token through both: the pool that credits the real
`balanceOf` delta stays exactly backed, while the one that credits the requested
face value goes insolvent on the first deposit — the last depositors out are left
short.

### Oracle validity  ✅ available

For any consumer of a Chainlink-style price feed. Reading `answer` without
validating the round is the textbook oracle mistake — a zero, a negative (which
`uint256`-wraps to ~1e77), a stale price, or a carried-over answer all sail
straight into your pricing:

```solidity
import {OracleValidityCheck, IPriceConsumer, ISettableAggregator} from "invariant-kit/src/checks/OracleValidityCheck.sol";

contract MyOracleTest is OracleValidityCheck {
    function test_priceConsumerIsSafe() public {
        (MyConsumer c, MockAgg agg) = /* wire consumer to a settable mock feed */;
        assertValidatesOracle(IPriceConsumer(address(c)), ISettableAggregator(address(agg)), 1 hours);
    }
}
```

`assertValidatesOracle` drives the feed into all four bad states and asserts your
consumer reverts on each. The reference pair shows a consumer that checks
`answer > 0`, `updatedAt`, staleness against `maxAge`, and `answeredInRound >=
roundId` passing, versus a naive one that serves zero, a wrapped-negative, and a
two-hour-old price as if current.

### ERC-4626 withdrawal rounding direction  ✅ available

ERC-4626 requires `withdraw(assets)` to round the share cost **up**. Reuse the
deposit path's floor-rounding and, once the share price drifts above 1:1, a small
withdrawal rounds to **zero** shares burned while the assets still leave — a free
withdrawal, repeatable until the yield is drained:

```solidity
import {WithdrawalRoundingCheck, IWithdrawVault} from "invariant-kit/src/checks/WithdrawalRoundingCheck.sol";
import {IERC20Mint} from "invariant-kit/src/modules/ERC4626Invariants.sol";

contract MyVaultRoundingTest is WithdrawalRoundingCheck {
    function test_withdrawRoundsInVaultFavour() public {
        (MyVault v, MyToken t) = /* deploy */;
        assertWithdrawRoundingFavorsVault(IWithdrawVault(address(v)), IERC20Mint(address(t)));
    }
}
```

`assertWithdrawRoundingFavorsVault` seeds an above-1:1 price and asserts a
one-unit asset withdrawal burns a non-zero share count. The reference pair proves
it bites: at a 10:1 price the wrong-rounding vault lets a zero-share account
withdraw assets for free, while the correct (round-up) vault reverts on the first
attempt.

### Roadmap

- More primitives (ERC-4626 rehypothecation, Uniswap v4 hooks, veToken/gauge
  math, cross-function reentrancy templates) as demand appears.

## Why

Every additional invariant a protocol runs before deployment is one fewer exploit
after. Writing them takes specialist knowledge most teams don't keep in-house;
this packages it so they don't have to.

## License

MIT.
