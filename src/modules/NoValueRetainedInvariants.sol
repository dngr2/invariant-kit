// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

/// @notice A batch/aggregator/forwarder entrypoint: it receives `msg.value`, fans
///         it out across a set of sub-calls, and must never keep any of the
///         caller's value for itself. Any unspent or skipped-sub-call remainder
///         has to be refunded before the call returns.
///
///         A real multicall/disperse/router is a superset of this — point the
///         harness at your own entrypoint.
interface IValueBatchForwarder {
    function forward(address[] calldata recipients, uint256[] calldata amounts) external payable;
}

/// @notice A sink that accepts ETH (a normal payable recipient).
contract AcceptingSink {
    receive() external payable {}
}

/// @notice A sink that rejects ETH (no payable fallback), so a sub-call to it
///         fails and is skipped — the exact condition that strands value in a
///         forwarder that does not refund the remainder.
contract RejectingSink {
    // no receive / payable fallback: any value-bearing call reverts
    function ping() external pure returns (bool) {
        return true;
    }
}

/// @notice Bounded random actor that drives {forward} with a mix of accepting and
///         rejecting recipients and random per-recipient amounts, always sending
///         at least the sum as `msg.value`. It holds ETH and accepts refunds, so
///         the only place value can end up stranded is inside the forwarder.
contract ValueForwarderHandler is Test {
    IValueBatchForwarder public immutable target;
    address[] public sinks;

    constructor(IValueBatchForwarder t) {
        target = t;
        sinks.push(address(new AcceptingSink()));
        sinks.push(address(new AcceptingSink()));
        sinks.push(address(new RejectingSink())); // the skip vector
        vm.deal(address(this), 1e24);
    }

    /// @dev Receive refunds of the unspent remainder.
    receive() external payable {}

    function forward(uint256 seed, uint256 a0, uint256 a1, uint256 extra) external {
        address[] memory recipients = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        recipients[0] = sinks[seed % sinks.length];
        recipients[1] = sinks[(seed / 7) % sinks.length];
        amounts[0] = bound(a0, 0, 1e18);
        amounts[1] = bound(a1, 0, 1e18);
        extra = bound(extra, 0, 1e18); // overpay: the remainder that must come back

        uint256 value = amounts[0] + amounts[1] + extra;
        if (value > address(this).balance) return; // never send more ETH than we hold
        target.forward{value: value}(recipients, amounts);
    }
}

/// @notice Drop-in no-value-retained invariant for a value-forwarding entrypoint.
///         After every entrypoint call the forwarder's ETH balance must be back at
///         its baseline (captured at set-up) — it retains nothing of the caller's
///         value.
///
///         The bug it catches is the classic stranded-ETH aggregator: a batch that
///         forwards what it can but forgets to refund the value of a skipped or
///         failed sub-call, so ETH accumulates in the forwarder where the next
///         caller (or anyone) can sweep it.
///
///         Extend it, implement {_setUpForwarder} to deploy/return your entrypoint,
///         and Foundry fuzzes batches and checks the balance after every call.
abstract contract NoValueRetainedInvariant is StdInvariant, Test {
    address internal targetAddr;
    uint256 internal baseline;
    ValueForwarderHandler internal handler;

    /// @dev Teams override: deploy/return the forwarding entrypoint under test.
    function _setUpForwarder() internal virtual returns (IValueBatchForwarder forwarder_);

    function setUp() public virtual {
        IValueBatchForwarder t = _setUpForwarder();
        targetAddr = address(t);
        baseline = targetAddr.balance;
        handler = new ValueForwarderHandler(t);
        targetContract(address(handler));
    }

    /// The forwarder must never retain the caller's value: its balance returns to
    /// the baseline after every entrypoint call.
    function invariant_noValueRetained() public view {
        assertEq(targetAddr.balance, baseline, "STRANDED VALUE: forwarder balance != baseline after an entrypoint call");
    }
}
