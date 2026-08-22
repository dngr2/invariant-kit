// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {WithdrawalRoundingCheck, IWithdrawVault} from "../src/checks/WithdrawalRoundingCheck.sol";
import {IERC20Mint} from "../src/modules/ERC4626Invariants.sol";
import {MockERC20} from "./reference/ReferenceVaults.sol";
import {RoundingVaultBase, CorrectRoundingVault, WrongWithdrawRoundingVault} from "./reference/RoundingVaults.sol";

/// The check passes against a CORRECT vault: withdrawing one unit of assets, at
/// an above-1:1 price, always burns at least one share.
contract WithdrawalRoundingCheckTest is WithdrawalRoundingCheck {
    function test_correctVault_passesTheCheck() public {
        MockERC20 t = new MockERC20();
        CorrectRoundingVault v = new CorrectRoundingVault(t);
        assertWithdrawRoundingFavorsVault(IWithdrawVault(address(v)), IERC20Mint(address(t)));
    }
}

/// Falsifiability proof: at a 10:1 price the wrong-rounding vault lets an account
/// holding ZERO shares withdraw assets one unit at a time, burning nothing each
/// time, until the yield is drained — while the correct vault reverts on the very
/// first such attempt (it would have to burn a share the attacker does not hold).
contract WithdrawalRoundingDemo is Test {
    address seeder = makeAddr("wr_seeder");
    address attacker = makeAddr("wr_attacker");

    function _seedToTenToOne(MockERC20 t, RoundingVaultBase vault) internal {
        t.mint(seeder, 100);
        vm.startPrank(seeder);
        t.approve(address(vault), type(uint256).max);
        vault.deposit(100, seeder);
        vm.stopPrank();
        t.mint(address(this), 900);
        t.transfer(address(vault), 900); // assets 1000, supply 100 => 10:1
    }

    function test_wrongRounding_freeWithdrawal_drainsYield() public {
        MockERC20 t = new MockERC20();
        WrongWithdrawRoundingVault v = new WrongWithdrawRoundingVault(t);
        _seedToTenToOne(t, v);

        assertEq(v.balanceOf(attacker), 0, "attacker starts with no shares");
        uint256 before = t.balanceOf(attacker);

        for (uint256 i; i < 50; i++) {
            vm.prank(attacker);
            uint256 burned = v.withdraw(1, attacker, attacker);
            assertEq(burned, 0, "each dust withdrawal rounds to 0 shares burned");
        }

        assertEq(v.balanceOf(attacker), 0, "attacker still holds no shares");
        assertEq(t.balanceOf(attacker) - before, 50, "attacker extracted 50 assets for free");
    }

    function test_correctRounding_freeWithdrawal_reverts() public {
        MockERC20 t = new MockERC20();
        CorrectRoundingVault v = new CorrectRoundingVault(t);
        _seedToTenToOne(t, v);

        // previewWithdraw(1) rounds UP to 1 share; the attacker holds none.
        vm.prank(attacker);
        vm.expectRevert(); // arithmetic underflow burning a share the attacker lacks
        v.withdraw(1, attacker, attacker);
    }
}
