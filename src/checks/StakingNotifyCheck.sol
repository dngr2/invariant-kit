// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

/// @notice Reusable check for the most common real staking-rewards finding:
///         an unrestricted `notifyRewardAmount`. When anyone can call it, a
///         griefer re-stretches the reward period with tiny amounts and dilutes
///         stakers' reward rate. Extend this in a test and point it at your
///         staking contract.
abstract contract StakingNotifyCheck is Test {
    /// @return restricted True if an arbitrary address is rejected by
    ///         `notifyRewardAmount(uint256)`.
    function isNotifyRestricted(address staking) internal returns (bool restricted) {
        address rando = makeAddr("ik_rando");
        vm.prank(rando);
        (bool ok,) = staking.call(abi.encodeWithSignature("notifyRewardAmount(uint256)", uint256(1)));
        return !ok;
    }

    /// @notice Fails if `notifyRewardAmount` is callable by an arbitrary address.
    function assertNotifyRestricted(address staking) internal {
        assertTrue(
            isNotifyRestricted(staking),
            "notifyRewardAmount is callable by an arbitrary address (reward dilution / griefing)"
        );
    }
}
