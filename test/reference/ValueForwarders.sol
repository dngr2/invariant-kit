// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ValueForwarderBase — a batch value forwarder
/// @notice Receives `msg.value`, sends each `amounts[i]` to `recipients[i]` on a
///         best-effort basis (a failed sub-call is skipped, not reverted), and
///         then decides what to do with anything left over. The only behaviour
///         that differs between the correct and the broken reference is the
///         post-loop handling, so the bug is isolated.
abstract contract ValueForwarderBase {
    function forward(address[] calldata recipients, uint256[] calldata amounts) external payable {
        require(recipients.length == amounts.length, "length mismatch");
        for (uint256 i; i < recipients.length; i++) {
            // best-effort: ignore failures so one bad recipient can't brick the batch
            (bool ok,) = recipients[i].call{value: amounts[i]}("");
            ok; // silence unused; a skipped sub-call leaves its value with us
        }
        _settleRemainder();
    }

    function _settleRemainder() internal virtual;
}

/// @title RefundingForwarder (CORRECT)
/// @notice Refunds everything unspent — overpayment and the value of any skipped
///         sub-call — back to the caller, so it ends every call holding nothing of
///         the caller's value.
contract RefundingForwarder is ValueForwarderBase {
    function _settleRemainder() internal override {
        uint256 left = address(this).balance;
        if (left > 0) {
            (bool ok,) = msg.sender.call{value: left}("");
            require(ok, "refund failed");
        }
    }
}

/// @title StrandingForwarder (VULNERABLE — strands unspent value)
/// @notice Forwards what it can and returns. When a sub-call is skipped (recipient
///         rejects) its value is left sitting in the forwarder — stranded ETH the
///         caller loses and anyone can later sweep. Nothing reverts.
///
///         `NoValueRetainedInvariant.invariant_noValueRetained` catches it: after a
///         batch with a skipped sub-call, `address(target).balance != baseline`.
contract StrandingForwarder is ValueForwarderBase {
    function _settleRemainder() internal override {
        // BUG: no refund — any unspent / skipped value stays stranded here.
    }
}
