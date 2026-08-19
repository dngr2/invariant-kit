// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ConstantProductInvariantHarness, IConstantProductAMM} from "../src/modules/ConstantProductInvariants.sol";
import {AMMRoundTripCheck} from "../src/checks/AMMRoundTripCheck.sol";
import {MiniAMM} from "./reference/MiniAMM.sol";
import {MiniAMMFixed} from "./reference/MiniAMMFixed.sol";

uint256 constant R = 1_000_000e18;

/// Invariant harness wired to the correct constant-product pool: k never
/// decreases across thousands of fuzzed swaps.
contract FixedAMMInvariants is ConstantProductInvariantHarness {
    function _setUpAMM() internal override returns (IConstantProductAMM) {
        return IConstantProductAMM(address(new MiniAMMFixed(R, R)));
    }
}

/// Demonstrates the module catches the value leak on the buggy (linear-price)
/// pool and clears the correct one.
contract AMMChecksDemo is AMMRoundTripCheck {
    function test_buggyAMM_leaksK() public {
        MiniAMM amm = new MiniAMM(R, R);
        uint256 k0 = amm.reserve0() * amm.reserve1();
        for (uint256 i; i < 5; i++) {
            uint256 out = amm.swap(10_000e18, true);
            amm.swap(out, false);
        }
        assertLt(amm.reserve0() * amm.reserve1(), k0, "expected the linear-price pool to leak k");
    }

    function test_buggyAMM_roundTripProfits() public {
        MiniAMM amm = new MiniAMM(R, R);
        uint256 back = roundTrip(IConstantProductAMM(address(amm)), 10_000e18);
        assertGe(back, 10_000e18, "expected a round-trip drain on the buggy pool");
    }

    function test_fixedAMM_noRoundTripProfit() public {
        MiniAMMFixed amm = new MiniAMMFixed(R, R);
        assertNoRoundTripProfit(IConstantProductAMM(address(amm)), 10_000e18);
    }
}
