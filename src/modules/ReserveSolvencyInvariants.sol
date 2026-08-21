// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

/// @notice The two-view surface every reserve-backed system reduces to. A bonding
///         curve, a savings vault, a CDP, a prediction market and a casino
///         bankroll are all the same shape: they hold some asset and, at any
///         instant, owe some amount they must be able to pay out right now.
///
///           - {assetBalance} — the assets the system actually holds this instant.
///           - {totalOwed}    — the assets it must be able to pay out this instant
///                              (deposits + accrued interest, open payouts, the
///                              redeem value of every outstanding claim, ...).
///
///         A real contract implements this in a few lines over its own state.
interface IReserveBacked {
    function assetBalance() external view returns (uint256);
    function totalOwed() external view returns (uint256);
}

/// @notice Drop-in reserve-solvency invariant. The system must, at every reachable
///         state, hold at least what it owes: `assetBalance() >= totalOwed()`.
///
///         This is the most reused property in DeFi review — anything that takes
///         custody of value and later has to return it collapses to it. The bug it
///         catches is a system that credits payouts (interest, rewards, winnings)
///         it does not actually have the reserves for, so liabilities silently
///         outgrow assets while nothing reverts.
///
///         Extend it, implement {_setUpSystem} to deploy your system and return it
///         together with the handler of your own actions to fuzz, and Foundry
///         drives the sequence and checks the property after every call.
abstract contract ReserveSolvencyInvariant is StdInvariant, Test {
    IReserveBacked internal system;

    /// @dev Teams override: deploy/return the system under test and the handler
    ///      contract exposing the user actions the fuzzer should drive.
    function _setUpSystem() internal virtual returns (IReserveBacked system_, address handler_);

    function setUp() public virtual {
        (IReserveBacked s, address h) = _setUpSystem();
        system = s;
        targetContract(h);
    }

    /// Reserves must always back liabilities: the assets held can never fall below
    /// what the system is obligated to pay out right now.
    function invariant_reserveCoversLiabilities() public view {
        assertGe(
            system.assetBalance(),
            system.totalOwed(),
            "UNDERWATER: assetBalance < totalOwed (reserves cannot cover liabilities)"
        );
    }
}
