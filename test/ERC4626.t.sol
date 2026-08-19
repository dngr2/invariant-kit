// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626InvariantHarness, IERC4626Like, IERC20Mint} from "../src/modules/ERC4626Invariants.sol";
import {ERC4626InflationCheck} from "../src/checks/ERC4626InflationCheck.sol";
import {MockERC20, NaiveVault, SafeVault} from "./reference/ReferenceVaults.sol";

/// Wire the invariant harness to the SAFE vault: demonstrates the drop-in harness
/// runs and the solvency/round-trip invariants hold on a correct vault (incl.
/// under the handler's donate/inflation actions).
contract SafeVaultInvariants is ERC4626InvariantHarness {
    function _setUpVault() internal override returns (IERC4626Like, IERC20Mint) {
        MockERC20 token = new MockERC20();
        SafeVault v = new SafeVault(token);
        return (IERC4626Like(address(v)), IERC20Mint(address(token)));
    }
}

/// Demonstrates the inflation exploit check: catches the naive vault, clears the
/// safe one — the "this vault is/ isn't inflatable" signal a team gets on their own.
contract InflationCheckDemo is ERC4626InflationCheck {
    function test_naiveVaultIsInflatable() public {
        MockERC20 token = new MockERC20();
        NaiveVault v = new NaiveVault(token);
        uint256 victimClaim = _runInflationAttack(IERC4626Like(address(v)), IERC20Mint(address(token)));
        // Victim is left with ~nothing on the vulnerable vault.
        assertLt(victimClaim, VICTIM_DEPOSIT / 100, "expected the naive vault to strand the victim");
    }

    function test_safeVaultResistsInflation() public {
        MockERC20 token = new MockERC20();
        SafeVault v = new SafeVault(token);
        assertNotInflatable(IERC4626Like(address(v)), IERC20Mint(address(token)));
    }
}
