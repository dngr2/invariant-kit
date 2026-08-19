// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {StakingNotifyCheck} from "../src/checks/StakingNotifyCheck.sol";
import {MockERC20} from "./reference/ReferenceVaults.sol";
import {StakingVulnerable, StakingSafe} from "./reference/ReferenceStaking.sol";

/// Demonstrates the staking notify check: catches the unrestricted
/// `notifyRewardAmount` on the vulnerable contract, clears the restricted one.
contract StakingNotifyDemo is StakingNotifyCheck {
    function _vulnerable() internal returns (address) {
        return address(new StakingVulnerable(new MockERC20(), new MockERC20()));
    }

    function _safe() internal returns (address) {
        return address(new StakingSafe(new MockERC20(), new MockERC20()));
    }

    function test_vulnerableNotifyIsUnrestricted() public {
        assertFalse(isNotifyRestricted(_vulnerable()), "expected anyone to be able to notify the vulnerable contract");
    }

    function test_safeNotifyIsRestricted() public {
        assertNotifyRestricted(_safe());
    }
}
