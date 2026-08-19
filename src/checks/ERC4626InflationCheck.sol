// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC4626Like, IERC20Mint} from "../modules/ERC4626Invariants.sol";

/// @notice Reusable first-depositor / share-inflation exploit check.
///         Extend it in a test and call {assertNotInflatable} against your vault
///         to get a concrete pass/fail (with a failing transaction if vulnerable),
///         not a vague warning.
abstract contract ERC4626InflationCheck is Test {
    uint256 internal constant VICTIM_DEPOSIT = 100e18;

    /// @dev Runs the classic attack: attacker mints 1 wei -> 1 share, donates
    ///      directly to the vault to inflate the share price, then a victim
    ///      deposits VICTIM_DEPOSIT.
    /// @return victimClaim assets the victim can still redeem afterwards.
    function _runInflationAttack(IERC4626Like vault, IERC20Mint asset) internal returns (uint256 victimClaim) {
        address attacker = makeAddr("ik_attacker");
        address victim = makeAddr("ik_victim");
        asset.mint(attacker, 1 + VICTIM_DEPOSIT);
        asset.mint(victim, VICTIM_DEPOSIT);

        vm.startPrank(attacker);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(1, attacker); // 1 wei -> 1 share
        asset.transfer(address(vault), VICTIM_DEPOSIT); // donate to inflate the price
        vm.stopPrank();

        vm.startPrank(victim);
        asset.approve(address(vault), type(uint256).max);
        uint256 victimShares = vault.deposit(VICTIM_DEPOSIT, victim);
        vm.stopPrank();

        victimClaim = vault.convertToAssets(victimShares);
    }

    /// @dev Passes iff the victim keeps more than half their deposit — i.e. the
    ///      vault is NOT meaningfully inflatable.
    function assertNotInflatable(IERC4626Like vault, IERC20Mint asset) internal {
        uint256 victimClaim = _runInflationAttack(vault, asset);
        assertGt(
            victimClaim,
            VICTIM_DEPOSIT / 2,
            "INFLATION: victim lost >50% of deposit to a first-depositor attack"
        );
    }
}
