// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IConstantProductAMM} from "../modules/ConstantProductInvariants.sol";

/// @notice A trader who swaps a→b and immediately b→a must not come out ahead;
///         if they do, the pricing leaks LP value. Extend this and call
///         {assertNoRoundTripProfit} against your pool.
abstract contract AMMRoundTripCheck is Test {
    function roundTrip(IConstantProductAMM amm, uint256 amountIn) internal returns (uint256 back) {
        uint256 out = amm.swap(amountIn, true);
        back = amm.swap(out, false);
    }

    function assertNoRoundTripProfit(IConstantProductAMM amm, uint256 amountIn) internal {
        assertLe(
            roundTrip(amm, amountIn),
            amountIn,
            "ROUND-TRIP DRAIN: trader got back more than they put in (LPs lose)"
        );
    }
}
