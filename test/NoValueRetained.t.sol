// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NoValueRetainedInvariant, IValueBatchForwarder} from "../src/modules/NoValueRetainedInvariants.sol";
import {ValueForwarderBase, RefundingForwarder, StrandingForwarder} from "./reference/ValueForwarders.sol";

/// Invariant harness wired to the CORRECT forwarder: after every fuzzed batch the
/// forwarder's balance is back at its baseline — it retains nothing. Pinned to
/// fail-on-revert so the campaign is non-hollow (every batch lands).
/// forge-config: default.invariant.fail-on-revert = true
contract GoodNoValueRetained is NoValueRetainedInvariant {
    function _setUpForwarder() internal override returns (IValueBatchForwarder) {
        return IValueBatchForwarder(address(new RefundingForwarder()));
    }
}

/// A recipient that rejects ETH, used to force a skipped sub-call.
contract Rejector {
    function ping() external pure returns (bool) {
        return true;
    }
}

/// Falsifiability proof: the same batch — one paying recipient plus one that
/// rejects — lands the caller's leftover value back on the refunding forwarder
/// (balance returns to baseline) but strands it in the non-refunding one, which
/// the invariant flags.
contract NoValueRetainedDemo is Test {
    receive() external payable {}

    function _batch() internal returns (address[] memory recipients, uint256[] memory amounts) {
        recipients = new address[](2);
        amounts = new uint256[](2);
        recipients[0] = address(this); // accepts
        recipients[1] = address(new Rejector()); // rejects -> sub-call skipped
        amounts[0] = 1 ether;
        amounts[1] = 1 ether;
    }

    function test_refunding_retainsNothing() public {
        RefundingForwarder f = new RefundingForwarder();
        (address[] memory r, uint256[] memory a) = _batch();

        f.forward{value: 2 ether}(r, a);

        assertEq(address(f).balance, 0, "correct forwarder must retain nothing (refunds the skipped value)");
    }

    function test_stranding_retainsSkippedValue() public {
        StrandingForwarder f = new StrandingForwarder();
        (address[] memory r, uint256[] memory a) = _batch();

        f.forward{value: 2 ether}(r, a);

        // The 1 ether meant for the rejecting recipient is stranded in the forwarder.
        assertEq(address(f).balance, 1 ether, "expected the skipped sub-call's value to be stranded");
    }
}
