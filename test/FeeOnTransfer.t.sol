// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FeeOnTransferInvariant, IFeeAware} from "../src/modules/FeeOnTransferInvariants.sol";
import {
    FeeOnTransferToken,
    IFeeToken,
    FeeAwarePoolBase,
    DeltaMeasuredPool,
    FaceValuePool
} from "./reference/FeeOnTransferPools.sol";

/// @notice A user-supplied handler: the actions the fuzzer drives against the
///         custody system with a FEE-ON-TRANSFER token in play (deposit,
///         withdraw). Kept deliberately small — this is all a real integrator
///         writes.
contract FeePoolHandler is Test {
    FeeAwarePoolBase public immutable pool;
    FeeOnTransferToken public immutable token;

    uint256 internal constant NUM_ACTORS = 3;
    address[] public actors;

    constructor(FeeAwarePoolBase p, FeeOnTransferToken t) {
        pool = p;
        token = t;
        for (uint256 i; i < NUM_ACTORS; i++) {
            address a = makeAddr(string.concat("ik_fot_", vm.toString(i)));
            actors.push(a);
            t.mint(a, 1e30);
            vm.prank(a);
            t.approve(address(p), type(uint256).max);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function deposit(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        amount = bound(amount, 0, token.balanceOf(a));
        if (amount == 0) return;
        vm.prank(a);
        pool.deposit(amount);
    }

    function withdraw(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        amount = bound(amount, 0, pool.creditOf(a));
        if (amount == 0) return;
        vm.prank(a);
        pool.withdraw(amount);
    }
}

/// Invariant harness wired to the CORRECT pool: credit stays backed by the real
/// token balance across fuzzed deposit/withdraw sequences with a 1%-fee token.
/// Pinned to fail-on-revert so the campaign is non-hollow (every action lands).
/// forge-config: default.invariant.fail-on-revert = true
contract GoodFeeOnTransfer is FeeOnTransferInvariant {
    function _setUpSystem() internal override returns (IFeeAware, address) {
        FeeOnTransferToken t = new FeeOnTransferToken(100); // 1% fee
        DeltaMeasuredPool p = new DeltaMeasuredPool(IFeeToken(address(t)));
        FeePoolHandler h = new FeePoolHandler(FeeAwarePoolBase(address(p)), t);
        return (IFeeAware(address(p)), address(h));
    }
}

/// Falsifiability proof: the SAME single fee-charged deposit keeps the
/// delta-measured pool exactly backed and leaves the face-value pool insolvent —
/// tripping the exact expression the invariant checks.
contract FeeOnTransferDemo is Test {
    address user = makeAddr("fot_user");

    function _fund(FeeAwarePoolBase pool, FeeOnTransferToken token) internal {
        token.mint(user, 100e18);
        vm.startPrank(user);
        token.approve(address(pool), type(uint256).max);
        pool.deposit(100e18); // 1% fee => only 99e18 actually arrives
        vm.stopPrank();
    }

    function test_deltaMeasured_staysBacked() public {
        FeeOnTransferToken t = new FeeOnTransferToken(100);
        DeltaMeasuredPool p = new DeltaMeasuredPool(IFeeToken(address(t)));
        _fund(p, t);

        assertLe(p.creditedTotal(), t.balanceOf(address(p)), "correct pool must stay backed");
        assertEq(p.creditedTotal(), 99e18, "credits the real 99e18 received");
        assertEq(t.balanceOf(address(p)), 99e18);
    }

    function test_faceValue_becomesInsolvent() public {
        FeeOnTransferToken t = new FeeOnTransferToken(100);
        FaceValuePool p = new FaceValuePool(IFeeToken(address(t)));
        _fund(p, t);

        assertGt(p.creditedTotal(), t.balanceOf(address(p)), "expected face-value credit to outrun balance");
        assertEq(p.creditedTotal(), 100e18, "credited the full 100e18 requested");
        assertEq(t.balanceOf(address(p)), 99e18, "but only 99e18 arrived");
    }
}
