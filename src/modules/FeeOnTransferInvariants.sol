// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

/// @notice The minimal surface any custody system exposes for the fee-on-transfer
///         class of bug. A pool, vault, escrow or router that pulls tokens in and
///         credits the depositor an internal balance reduces to two numbers:
///
///           - {creditedTotal} — the sum of the internal balances it has promised
///                               depositors (what it thinks it received).
///           - {tokenBalance}  — the tokens it actually holds this instant.
///
///         A real contract implements this in a couple of lines over its own state.
interface IFeeAware {
    function creditedTotal() external view returns (uint256);
    function tokenBalance() external view returns (uint256);
}

/// @notice Drop-in fee-on-transfer accounting invariant. The credit a custody
///         system hands out must never exceed the tokens it actually holds:
///         `creditedTotal() <= tokenBalance()`.
///
///         The bug: a contract assumes `transferFrom(user, self, amount)` delivers
///         exactly `amount`, and credits the depositor that face value. With a
///         fee-on-transfer (or rebasing/deflationary) token, fewer tokens actually
///         arrive, so the credited liabilities silently outgrow the real balance.
///         The last depositors to exit are left short and the pool is insolvent —
///         a bug no example-based test with a plain ERC-20 will ever surface.
///
///         The fix a correct system uses is measuring the real balance delta
///         (`balanceOf(self)` before/after the pull) and crediting THAT, not the
///         requested amount. Point this at your pool with a fee-charging token in
///         the handler and Foundry hunts a state where credit outruns balance.
///
///         Extend it, implement {_setUpSystem} to deploy your system and return it
///         together with the handler of your own actions to fuzz, and Foundry
///         drives the sequence and checks the property after every call.
abstract contract FeeOnTransferInvariant is StdInvariant, Test {
    IFeeAware internal system;

    /// @dev Teams override: deploy/return the system under test and the handler
    ///      contract exposing the user actions the fuzzer should drive (deposits
    ///      with a fee-on-transfer token, withdrawals, ...).
    function _setUpSystem() internal virtual returns (IFeeAware system_, address handler_);

    function setUp() public virtual {
        (IFeeAware s, address h) = _setUpSystem();
        system = s;
        targetContract(h);
    }

    /// Credited liabilities must always be backed by tokens actually held: the
    /// internal accounting can never promise more than the real balance.
    function invariant_creditBackedByBalance() public view {
        assertLe(
            system.creditedTotal(),
            system.tokenBalance(),
            "PHANTOM CREDIT: creditedTotal > tokenBalance (face-value accounting over a fee-on-transfer token)"
        );
    }
}
