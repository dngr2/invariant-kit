// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProxyInitCheck} from "../src/checks/ProxyInitCheck.sol";
import {Proxy} from "./reference/Proxy.sol";
import {LogicV1, LogicV1Fixed} from "./reference/Logic.sol";
import {LogicV2Bad, LogicV2Good} from "./reference/LogicV2.sol";

interface ILogic {
    function initialize(address owner) external;
    function owner() external view returns (address);
    function deposit() external payable;
    function totalDeposited() external view returns (uint256);
}

/// Demonstrates the proxy checks: the unprotected initializer is re-callable (a
/// takeover), the guarded one is not; and a storage-colliding upgrade corrupts
/// `owner` while an append-only upgrade preserves it.
contract ProxyChecksDemo is ProxyInitCheck {
    address admin = makeAddr("admin");
    address alice = makeAddr("alice");

    function _initedProxy(bool guarded) internal returns (address) {
        address impl = guarded ? address(new LogicV1Fixed()) : address(new LogicV1());
        Proxy p = new Proxy(impl, admin);
        ILogic(address(p)).initialize(alice); // legitimate first init
        return address(p);
    }

    function test_unprotectedInitializer_isExploitable() public {
        assertFalse(isInitializerProtected(_initedProxy(false)), "expected the unprotected initializer to be re-callable");
    }

    function test_fixedInitializer_isProtected() public {
        assertInitializerProtected(_initedProxy(true));
    }

    function test_storageCollisionUpgrade_corruptsOwner() public {
        Proxy p = new Proxy(address(new LogicV1()), admin);
        ILogic v = ILogic(address(p));
        v.initialize(alice);
        vm.deal(alice, 5 ether);
        vm.prank(alice);
        v.deposit{value: 5 ether}();
        assertEq(v.owner(), alice);

        address v2 = address(new LogicV2Bad()); // pre-deploy so the prank hits upgradeTo
        vm.prank(admin);
        p.upgradeTo(v2);
        assertTrue(v.owner() != alice, "storage-collision upgrade should corrupt owner");
    }

    function test_appendOnlyUpgrade_preservesOwner() public {
        Proxy p = new Proxy(address(new LogicV1()), admin);
        ILogic v = ILogic(address(p));
        v.initialize(alice);

        address v2 = address(new LogicV2Good());
        vm.prank(admin);
        p.upgradeTo(v2);
        assertEq(v.owner(), alice, "append-only upgrade preserves owner");
    }
}
