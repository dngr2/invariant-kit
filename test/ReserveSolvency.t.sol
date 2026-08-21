// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ReserveSolvencyInvariant, IReserveBacked} from "../src/modules/ReserveSolvencyInvariants.sol";
import {MockERC20} from "./reference/ReferenceVaults.sol";
import {SavingsVaultBase, ReserveCappedSavingsVault, OverpromisingSavingsVault} from "./reference/SavingsVaults.sol";

/// @notice A user-supplied handler: the actions the fuzzer drives against the
///         reserve-backed system (deposit, withdraw, accrue interest). Kept
///         deliberately small — this is all a real integrator writes.
contract SavingsVaultHandler is Test {
    SavingsVaultBase public immutable vault;
    MockERC20 public immutable token;

    uint256 internal constant NUM_ACTORS = 3;
    address[] public actors;

    constructor(SavingsVaultBase v, MockERC20 t) {
        vault = v;
        token = t;
        for (uint256 i; i < NUM_ACTORS; i++) {
            address a = makeAddr(string.concat("ik_saver_", vm.toString(i)));
            actors.push(a);
            t.mint(a, 1e30);
            vm.prank(a);
            t.approve(address(v), type(uint256).max);
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
        vault.deposit(amount);
    }

    function withdraw(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        amount = bound(amount, 0, vault.owedTo(a));
        if (amount == 0) return;
        vm.prank(a);
        vault.withdraw(amount);
    }

    function accrue(uint256 seed, uint256 interest) external {
        address a = _actor(seed);
        interest = bound(interest, 0, 1e24);
        if (interest == 0) return;
        vault.accrue(a, interest);
    }
}

/// Invariant harness wired to the CORRECT vault: reserves always cover
/// liabilities across fuzzed deposit/withdraw/accrue sequences. Pinned to
/// fail-on-revert so the campaign is non-hollow (every action lands).
/// forge-config: default.invariant.fail-on-revert = true
contract GoodReserveSolvency is ReserveSolvencyInvariant {
    function _setUpSystem() internal override returns (IReserveBacked, address) {
        MockERC20 t = new MockERC20();
        ReserveCappedSavingsVault v = new ReserveCappedSavingsVault(t);
        t.mint(address(v), 1_000e18); // pre-funded reserve buffer to pay interest from
        SavingsVaultHandler h = new SavingsVaultHandler(v, t);
        return (IReserveBacked(address(v)), address(h));
    }
}

/// Falsifiability proof: the same "credit interest" action stays solvent on the
/// reserve-capped vault and breaks solvency on the overpromising one — which
/// credits interest it holds no reserves for — tripping the exact expression the
/// invariant checks.
contract ReserveSolvencyDemo is Test {
    address saver = makeAddr("saver");

    function test_reserveCapped_staysSolvent() public {
        MockERC20 t = new MockERC20();
        ReserveCappedSavingsVault v = new ReserveCappedSavingsVault(t);

        t.mint(saver, 100e18);
        vm.startPrank(saver);
        t.approve(address(v), type(uint256).max);
        v.deposit(100e18);
        vm.stopPrank();

        t.mint(address(v), 30e18); // reserve buffer of 30
        v.accrue(saver, 50e18); // asks for 50, only 30 is backed

        assertGe(v.assetBalance(), v.totalOwed(), "correct vault must stay solvent");
        assertEq(v.totalOwed(), 130e18, "interest is capped to the 30 reserve");
        assertEq(v.assetBalance(), 130e18);
    }

    function test_overpromising_breaksSolvency() public {
        MockERC20 t = new MockERC20();
        OverpromisingSavingsVault v = new OverpromisingSavingsVault(t);

        t.mint(saver, 100e18);
        vm.startPrank(saver);
        t.approve(address(v), type(uint256).max);
        v.deposit(100e18);
        vm.stopPrank();

        v.accrue(saver, 50e18); // credited with no reserve behind it

        assertLt(v.assetBalance(), v.totalOwed(), "expected unbacked interest to break solvency");
        assertEq(v.assetBalance(), 100e18);
        assertEq(v.totalOwed(), 150e18, "owes 150 while holding 100");
    }
}
