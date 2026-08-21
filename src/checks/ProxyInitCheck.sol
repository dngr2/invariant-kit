// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

/// @notice Checks that a proxy's `initialize(address)` cannot be called a second
///         time. An unprotected initializer behind a proxy is a direct ownership
///         takeover — anyone re-initializes and drains. Initialize your proxy
///         first, then call {assertInitializerProtected}.
abstract contract ProxyInitCheck is Test {
    /// @return protected True if a second `initialize(address)` by an arbitrary
    ///         caller reverts.
    function isInitializerProtected(address proxy) internal returns (bool protected) {
        address attacker = makeAddr("ik_attacker");
        vm.prank(attacker);
        (bool ok,) = proxy.call(abi.encodeWithSignature("initialize(address)", attacker));
        return !ok;
    }

    function assertInitializerProtected(address proxy) internal {
        assertTrue(
            isInitializerProtected(proxy), "initialize is callable again: unprotected initializer -> ownership takeover"
        );
    }
}
