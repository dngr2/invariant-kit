// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {
    ProfitLockingInvariantHarness,
    IProfitLockingVault,
    IERC20Mint
} from "../src/modules/ProfitLockingInvariants.sol";
import {MockERC20} from "./reference/ReferenceVaults.sol";
import {ProfitLockingBase, ProfitLockingVault, BrokenProfitLockingVault} from "./reference/ProfitLockingVaults.sol";

/// Invariant harness wired to the CORRECT profit-locking vault: solvency and
/// locked-share accounting hold, and the handler's inline anti-sandwich /
/// PPS-monotonicity checks pass across fuzzed deposit/redeem/report/warp runs.
contract GoodProfitLockingInvariants is ProfitLockingInvariantHarness {
    function _setUpVault() internal override returns (IProfitLockingVault, IERC20Mint) {
        MockERC20 a = new MockERC20();
        ProfitLockingVault v = new ProfitLockingVault(a);
        return (IProfitLockingVault(address(v)), IERC20Mint(address(a)));
    }
}

/// Falsifiability proof: the anti-sandwich property — the price per share must
/// not move in the block a gain is reported — holds on the correct vault and is
/// violated on the broken one that credits profit instantly.
contract ProfitLockingReportDemo is Test {
    address user = makeAddr("user");

    function _seed(MockERC20 a, ProfitLockingBase v) internal {
        a.mint(user, 1_000e18);
        vm.startPrank(user);
        a.approve(address(v), type(uint256).max);
        v.deposit(1_000e18, user);
        vm.stopPrank();
    }

    function _report(MockERC20 a, ProfitLockingBase v, uint256 gain) internal {
        a.mint(address(this), gain);
        a.approve(address(v), gain);
        v.report(gain);
    }

    function test_goodVault_noInstantPPSJumpOnReport() public {
        MockERC20 a = new MockERC20();
        ProfitLockingVault v = new ProfitLockingVault(a);
        _seed(a, v);

        uint256 pps0 = v.pricePerShare();
        _report(a, v, 100e18);
        uint256 pps1 = v.pricePerShare();
        assertApproxEqAbs(pps1, pps0, 1e6, "report must not move PPS in-block on the correct vault");

        // ...but the profit does accrue as the lock unwinds.
        vm.warp(block.timestamp + 7 days);
        assertGt(v.pricePerShare(), pps1, "profit should unlock into PPS over time");
    }

    function test_brokenVault_instantPPSJumpOnReport() public {
        MockERC20 a = new MockERC20();
        BrokenProfitLockingVault v = new BrokenProfitLockingVault(a);
        _seed(a, v);

        uint256 pps0 = v.pricePerShare();
        _report(a, v, 100e18);
        uint256 pps1 = v.pricePerShare();

        // The property the module enforces is violated: PPS jumps in-block.
        assertGt(pps1, pps0 + 1e6, "expected the broken vault to jump PPS in the report block");
    }
}
