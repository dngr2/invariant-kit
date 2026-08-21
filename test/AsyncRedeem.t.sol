// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AsyncRedeemConservationCheck, IAsyncRedeemVault} from "../src/checks/AsyncRedeemConservationCheck.sol";
import {MockERC20} from "./reference/ReferenceVaults.sol";
import {AsyncRedeemBase, AsyncRedeemVault, BrokenAsyncRedeemVault} from "./reference/AsyncRedeemVault.sol";

/// Demonstrates the async-redeem conservation check: it clears the correct vault
/// (reserve == sum of claims, backed by held assets) and catches the broken one
/// that drops the reserve accounting on fulfilment.
contract AsyncRedeemConservationDemo is AsyncRedeemConservationCheck {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function _controllers() internal view returns (address[] memory c) {
        c = new address[](2);
        c[0] = alice;
        c[1] = bob;
    }

    /// @dev Two deposits, two redeem requests, both fulfilled — leaving 60 assets
    ///      reserved (40 alice, 20 bob) against 150 held.
    function _run(AsyncRedeemBase v, MockERC20 a) internal {
        a.mint(alice, 100e18);
        a.mint(bob, 50e18);

        vm.startPrank(alice);
        a.approve(address(v), type(uint256).max);
        v.deposit(100e18);
        v.requestRedeem(40e18, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        a.approve(address(v), type(uint256).max);
        v.deposit(50e18);
        v.requestRedeem(20e18, bob);
        vm.stopPrank();

        v.fulfillRedeem(alice);
        v.fulfillRedeem(bob);
    }

    function test_correctVault_reserveConserved() public {
        MockERC20 a = new MockERC20();
        AsyncRedeemVault v = new AsyncRedeemVault(a);
        _run(v, a);
        assertReserveConserved(IAsyncRedeemVault(address(v)), _controllers());
    }

    function test_brokenVault_reserveLeaks() public {
        MockERC20 a = new MockERC20();
        BrokenAsyncRedeemVault v = new BrokenAsyncRedeemVault(a);
        _run(v, a);

        // The exact property the check enforces is violated: 60 claimable, 0 reserved.
        uint256 sumClaimable = v.claimableRedeemAssets(alice) + v.claimableRedeemAssets(bob);
        assertEq(sumClaimable, 60e18, "controllers can still claim 60");
        assertEq(v.totalReserved(), 0, "but the reserve was never recorded");
        assertTrue(sumClaimable != v.totalReserved(), "expected the dropped reserve accounting to leak");
    }
}
