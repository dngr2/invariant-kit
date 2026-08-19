// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MiniAMM (VULNERABLE)
/// @notice A two-asset constant-product pool. Reserves are tracked internally;
/// `swap` moves the pool from one side to the other.
///
/// The bug is in the pricing. A constant-product pool must quote
/// `out = reserveOut * inWithFee / (reserveIn + inWithFee)`, which keeps the
/// product `reserveIn * reserveOut` from ever shrinking. This version instead
/// quotes linearly, `out = reserveOut * amountIn / reserveIn`, and takes no fee.
/// Every swap then *decreases* the product, leaking value out of the pool — a
/// trader can round-trip in and out and come out ahead, draining the LPs.
///
/// A stateful invariant test (test/invariant) that only knows the rule "the
/// product must never decrease" finds this by fuzzing swaps, without being told
/// where the bug is.
contract MiniAMM {
    uint256 public reserve0;
    uint256 public reserve1;

    constructor(uint256 r0, uint256 r1) {
        reserve0 = r0;
        reserve1 = r1;
    }

    function k() external view returns (uint256) {
        return reserve0 * reserve1;
    }

    /// @param amountIn amount of the input asset added to the pool
    /// @param zeroForOne true to sell asset0 for asset1
    /// @return amountOut amount of the output asset removed from the pool
    function swap(uint256 amountIn, bool zeroForOne) external returns (uint256 amountOut) {
        require(amountIn > 0, "amountIn=0");
        (uint256 rIn, uint256 rOut) = zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);

        // BUG: linear price, no fee. Overpays and shrinks reserve0*reserve1.
        amountOut = (rOut * amountIn) / rIn;
        require(amountOut < rOut, "insufficient liquidity");

        rIn += amountIn;
        rOut -= amountOut;
        (reserve0, reserve1) = zeroForOne ? (rIn, rOut) : (rOut, rIn);
    }
}
