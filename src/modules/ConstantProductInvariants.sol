// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

/// @notice Minimal constant-product AMM surface. A real x*y=k pool satisfies this.
interface IConstantProductAMM {
    function reserve0() external view returns (uint256);
    function reserve1() external view returns (uint256);
    function swap(uint256 amountIn, bool zeroForOne) external returns (uint256 amountOut);
}

/// @notice Fuzzes random swaps in both directions without draining the pool.
contract AMMHandler is Test {
    IConstantProductAMM public immutable amm;

    constructor(IConstantProductAMM a) {
        amm = a;
    }

    function swap(uint256 amountIn, bool zeroForOne) external {
        uint256 rIn = zeroForOne ? amm.reserve0() : amm.reserve1();
        if (rIn <= 1) return;
        amountIn = bound(amountIn, 1, rIn - 1);
        try amm.swap(amountIn, zeroForOne) returns (uint256) {} catch {}
    }
}

/// @notice Drop-in AMM invariant harness. Extend it, return your pool from
///         {_setUpAMM}, and Foundry fuzzes that the constant product never
///         decreases — the property that catches value-leaking pricing (linear
///         quotes, missing fee, wrong rounding) without being told the bug.
abstract contract ConstantProductInvariantHarness is StdInvariant, Test {
    IConstantProductAMM internal amm;
    uint256 internal k0;

    /// @dev Teams override: return the pool under test (seeded with reserves).
    function _setUpAMM() internal virtual returns (IConstantProductAMM);

    function setUp() public virtual {
        amm = _setUpAMM();
        k0 = amm.reserve0() * amm.reserve1();
        AMMHandler h = new AMMHandler(amm);
        targetContract(address(h));
    }

    function invariant_kNeverDecreases() public view {
        assertGe(
            amm.reserve0() * amm.reserve1(),
            k0,
            "constant-product k decreased: value leaked from the pool"
        );
    }
}
