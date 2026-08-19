# invariant-kit

Drop-in Foundry invariants and known-exploit checks for the DeFi primitives that
lose money while every line looks correct. Point a module at your own contract
and let Foundry fuzz the properties that actually matter — or run a coded exploit
check and get a failing transaction if the bug is present, not a vague warning.

The bugs this targets are the ones that don't revert and pass a normal test
suite: ERC-4626 share inflation, reward-accounting mistakes, AMM value leaks,
proxy storage collisions. Each module is self-contained and depends only on
`forge-std`.

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

### Roadmap

- **Staking** — reward-conservation invariant harness (extending the notify check).
- More primitives (lending, ERC-4626 rehypothecation, Uniswap v4 hooks) as demand appears.

## Why

Every additional invariant a protocol runs before deployment is one fewer exploit
after. Writing them takes specialist knowledge most teams don't keep in-house;
this packages it so they don't have to.

## License

MIT.
