// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {OracleValidityCheck, IPriceConsumer, ISettableAggregator} from "../src/checks/OracleValidityCheck.sol";
import {MockAggregator, IAggregator, SafePriceConsumer, NaivePriceConsumer} from "./reference/OracleConsumers.sol";

/// The check passes against a CORRECT consumer: it rejects zero, negative,
/// carried-over and stale answers, and accepts a fresh valid one.
contract OracleValidityCheckTest is OracleValidityCheck {
    function test_safeConsumer_passesTheCheck() public {
        MockAggregator agg = new MockAggregator();
        SafePriceConsumer c = new SafePriceConsumer(IAggregator(address(agg)), 1 hours);
        assertValidatesOracle(IPriceConsumer(address(c)), ISettableAggregator(address(agg)), 1 hours);
    }
}

/// Falsifiability proof: the SAME bad answers the safe consumer rejects are
/// swallowed by the naive one — zero passes through, a negative answer wraps to
/// ~1e77, a stale price is served as current. Each is a concrete mispricing.
contract OracleValidityDemo is Test {
    MockAggregator internal agg;
    SafePriceConsumer internal safe;
    NaivePriceConsumer internal naive;

    function setUp() public {
        vm.warp(1_700_000_000);
        agg = new MockAggregator();
        safe = new SafePriceConsumer(IAggregator(address(agg)), 1 hours);
        naive = new NaivePriceConsumer(IAggregator(address(agg)));
    }

    function test_validPrice_bothReturnIt() public {
        agg.setRoundData(1, 2000e8, block.timestamp, 1);
        assertEq(safe.getPrice(), 2000e8);
        assertEq(naive.getPrice(), 2000e8);
    }

    function test_zeroAnswer_safeReverts_naiveAccepts() public {
        agg.setRoundData(2, 0, block.timestamp, 2);
        vm.expectRevert(bytes("bad price"));
        safe.getPrice();
        assertEq(naive.getPrice(), 0, "naive serves a price of zero");
    }

    function test_negativeAnswer_safeReverts_naiveWrapsHuge() public {
        agg.setRoundData(3, -1, block.timestamp, 3);
        vm.expectRevert(bytes("bad price"));
        safe.getPrice();
        assertEq(naive.getPrice(), type(uint256).max, "naive wraps a negative answer to ~1e77");
    }

    function test_staleAnswer_safeReverts_naiveServesStale() public {
        agg.setRoundData(4, 2000e8, block.timestamp, 4);
        vm.warp(block.timestamp + 2 hours); // older than the 1h maxAge
        vm.expectRevert(bytes("stale price"));
        safe.getPrice();
        assertEq(naive.getPrice(), 2000e8, "naive serves a two-hour-old price as current");
    }

    function test_carriedOverAnswer_safeReverts_naiveAccepts() public {
        agg.setRoundData(20, 2000e8, block.timestamp, 19); // answeredInRound < roundId
        vm.expectRevert(bytes("stale round"));
        safe.getPrice();
        assertEq(naive.getPrice(), 2000e8, "naive trusts a carried-over answer");
    }
}
