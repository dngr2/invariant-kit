// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

/// @notice Your price consumer, reduced to the one call the rest of your protocol
///         trusts: {getPrice} must return a usable price or REVERT. It must never
///         hand back a zero, a negative-wrapped-to-huge, or a stale value.
interface IPriceConsumer {
    function getPrice() external view returns (uint256);
}

/// @notice The settable feed the check drives into each bad state. In your own
///         suite, deploy a mock aggregator with this shape, wire it into your
///         consumer, and point the check at both.
interface ISettableAggregator {
    function setRoundData(uint80 roundId, int256 answer, uint256 updatedAt, uint80 answeredInRound) external;
}

/// @notice Reusable oracle-validity exploit check. Extend it in a test and call
///         {assertValidatesOracle} against your price consumer to get a concrete
///         pass/fail: it drives the aggregator through the four answers that have
///         drained real protocols and asserts your consumer rejects every one.
///
///         The bug class: reading `answer` from `latestRoundData()` (or
///         `latestAnswer()`) and using it without checking it. The failure modes:
///           - zero answer (feed not yet posted / mis-deployed) → division or
///             mispricing at price 0;
///           - negative answer → `uint256(answer)` becomes ~1e77, arbitrary
///             mispricing;
///           - stale answer (`updatedAt` far in the past) → trading on a price the
///             feed abandoned, classic during depeg/outage;
///           - carried-over answer (`answeredInRound < roundId`) → a round that
///             never actually updated.
///
///         A correct consumer validates all four and reverts; a naive one sails
///         through. This check makes that difference a failing transaction.
abstract contract OracleValidityCheck is Test {
    /// @dev Drives every bad-answer scenario and asserts the consumer rejects it.
    ///      `maxAge` must match the staleness threshold the consumer enforces.
    ///      Requires a fresh, valid round to be accepted first (setup sanity).
    function assertValidatesOracle(IPriceConsumer consumer, ISettableAggregator agg, uint256 maxAge) internal {
        uint256 t = block.timestamp;

        // Setup sanity: a fresh, valid round must yield a usable price, else the
        // check is misconfigured (wrong maxAge / unwired aggregator).
        agg.setRoundData(10, 2000e8, t, 10);
        require(consumer.getPrice() > 0, "SETUP: consumer rejected a valid, fresh price");

        // 1) zero answer
        agg.setRoundData(11, 0, t, 11);
        _expectRejected(consumer, "zero answer accepted");

        // 2) negative answer (wraps to ~1e77 under uint256 cast)
        agg.setRoundData(12, -1, t, 12);
        _expectRejected(consumer, "negative answer accepted");

        // 3) carried-over answer: answeredInRound < roundId
        agg.setRoundData(20, 2000e8, t, 19);
        _expectRejected(consumer, "carried-over answer (answeredInRound < roundId) accepted");

        // 4) stale answer: a valid round, then time advances past maxAge
        agg.setRoundData(21, 2000e8, t, 21);
        vm.warp(t + maxAge + 1);
        _expectRejected(consumer, "stale answer (older than maxAge) accepted");
        vm.warp(t);
    }

    function _expectRejected(IPriceConsumer consumer, string memory why) private view {
        try consumer.getPrice() returns (uint256) {
            revert(string.concat("ORACLE: ", why));
        } catch {
            // reverted as required — good
        }
    }
}
