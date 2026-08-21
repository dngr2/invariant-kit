// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NoOverfillInvariant, IOrderSettlement} from "../src/modules/NoOverfillInvariants.sol";
import {OrderSettlerBase, CEIOrderSettler, ReentrantOrderSettler, ReentrantTaker} from "./reference/OrderSettlers.sol";

/// Invariant harness wired to the CORRECT (CEI) settler: no order is ever
/// overfilled and every fill advances the taker's nonce by exactly one across
/// fuzzed fill sequences. Pinned to fail-on-revert so the campaign is non-hollow.
/// forge-config: default.invariant.fail-on-revert = true
contract GoodNoOverfill is NoOverfillInvariant {
    function _setUpBook() internal override returns (IOrderSettlement, bytes32[] memory) {
        CEIOrderSettler s = new CEIOrderSettler();
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = keccak256("order-a");
        ids[1] = keccak256("order-b");
        s.createOrder(ids[0], 500e18);
        s.createOrder(ids[1], 250e18);
        return (IOrderSettlement(address(s)), ids);
    }
}

/// Falsifiability proof: a taker that re-enters {fill} during its payout. Against
/// the CEI settler the reentrant fill fails the overfill check and the attack
/// reverts; against the settler that records `filled` after the transfer it fills
/// the same open amount twice, driving `filled` past `orderSize`.
contract NoOverfillReentrancyDemo is Test {
    bytes32 internal constant ID = keccak256("otc-1");
    uint256 internal constant SIZE = 100e18;

    function test_ceiSettler_reentrancyReverts_noOverfill() public {
        CEIOrderSettler s = new CEIOrderSettler();
        s.createOrder(ID, SIZE);
        vm.deal(address(s), 1_000e18); // fund payouts

        ReentrantTaker taker = new ReentrantTaker();
        vm.expectRevert(); // reentrant second fill trips the overfill check, whole tx reverts
        taker.attack(OrderSettlerBase(payable(address(s))), ID, SIZE);

        assertEq(s.filled(ID), 0, "no fill should have landed");
        assertLe(s.filled(ID), s.orderSize(ID), "correct settler is never overfilled");
    }

    function test_reentrantSettler_doubleFills_overfills() public {
        ReentrantOrderSettler s = new ReentrantOrderSettler();
        s.createOrder(ID, SIZE);
        vm.deal(address(s), 1_000e18); // fund payouts

        ReentrantTaker taker = new ReentrantTaker();
        taker.attack(OrderSettlerBase(payable(address(s))), ID, SIZE);

        // Same open amount filled twice: filled ends at 2x size, past orderSize.
        assertEq(s.filled(ID), 2 * SIZE, "expected the reentrant double-fill");
        assertGt(s.filled(ID), s.orderSize(ID), "OVERFILL: filled exceeds orderSize");
        assertEq(s.nonceOf(address(taker)), 2, "the same order executed twice (replay)");
    }
}
