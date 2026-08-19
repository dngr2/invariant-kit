// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MiniAMMFixed
/// @notice The same pool with the correct constant-product formula and a 0.3%
/// fee. `out = reserveOut * inWithFee / (reserveIn + inWithFee)`, rounded down,
/// so `reserve0 * reserve1` never decreases — the fuzzed invariant holds.
contract MiniAMMFixed {
    uint256 public reserve0;
    uint256 public reserve1;

    constructor(uint256 r0, uint256 r1) {
        reserve0 = r0;
        reserve1 = r1;
    }

    function k() external view returns (uint256) {
        return reserve0 * reserve1;
    }

    function swap(uint256 amountIn, bool zeroForOne) external returns (uint256 amountOut) {
        require(amountIn > 0, "amountIn=0");
        (uint256 rIn, uint256 rOut) = zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);

        uint256 inWithFee = (amountIn * 997) / 1000;
        amountOut = (rOut * inWithFee) / (rIn + inWithFee);
        require(amountOut < rOut, "insufficient liquidity");

        rIn += amountIn;
        rOut -= amountOut;
        (reserve0, reserve1) = zeroForOne ? (rIn, rOut) : (rOut, rIn);
    }
}
