// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {
    LendingInvariantHarness,
    ILendingMarket,
    IERC20Mintable,
    ISettableOracle,
    IERC20Like
} from "../src/modules/LendingInvariants.sol";
import {MockERC20} from "./reference/ReferenceVaults.sol";
import {MockOracle, LendingMarketBase, MiniLendingMarket, BrokenLendingMarket} from "./reference/MiniLendingMarket.sol";

uint256 constant LLTV = 0.8e18;

/// Invariant harness wired to the CORRECT market: solvency, no-over-lending,
/// no-phantom-bad-debt and collateral backing all hold across thousands of
/// fuzzed borrow/repay/price/liquidate sequences (bad debt included).
contract GoodLendingInvariants is LendingInvariantHarness {
    function _setUpMarket()
        internal
        override
        returns (ILendingMarket, IERC20Mintable, IERC20Mintable, ISettableOracle)
    {
        MockERC20 loan = new MockERC20();
        MockERC20 coll = new MockERC20();
        MockOracle oracle = new MockOracle(1e18);
        MiniLendingMarket m = new MiniLendingMarket(loan, coll, oracle, LLTV);
        return (
            ILendingMarket(address(m)),
            IERC20Mintable(address(loan)),
            IERC20Mintable(address(coll)),
            ISettableOracle(address(oracle))
        );
    }
}

/// Falsifiability proof: run the SAME bad-debt liquidation against the correct
/// and the broken market. The correct one stays solvent; the broken one — which
/// forgets to socialise the loss — trips the exact solvency expression the
/// invariant harness checks.
contract LendingBadDebtDemo is Test {
    address lender = makeAddr("lender");
    address borrower = makeAddr("borrower");
    address liquidator = makeAddr("liquidator");

    /// @dev Drives a position into bad debt and returns the market handles so the
    ///      test can read the post-liquidation books.
    function _runBadDebt(LendingMarketBase m, MockERC20 loan, MockERC20 coll, MockOracle oracle) internal {
        loan.mint(lender, 1_000e18);
        coll.mint(borrower, 100e18);
        loan.mint(liquidator, 1_000e18);

        vm.startPrank(lender);
        loan.approve(address(m), type(uint256).max);
        m.supply(1_000e18);
        vm.stopPrank();

        vm.startPrank(borrower);
        coll.approve(address(m), type(uint256).max);
        m.supplyCollateral(100e18); // value 100 @ price 1e18, maxBorrow 80
        m.borrow(80e18);
        vm.stopPrank();

        oracle.setPrice(0.5e18); // collateral now worth 50; 80 debt is underwater

        vm.startPrank(liquidator);
        loan.approve(address(m), type(uint256).max);
        m.liquidate(borrower); // seizes all collateral, ~47.6 repaid, ~32.4 bad debt
        vm.stopPrank();
    }

    function _solvent(LendingMarketBase m, MockERC20 loan) internal view returns (bool) {
        return loan.balanceOf(address(m)) + m.totalBorrowAssets() >= m.totalSupplyAssets();
    }

    function test_goodMarket_badDebt_staysSolvent() public {
        MockERC20 loan = new MockERC20();
        MockERC20 coll = new MockERC20();
        MockOracle oracle = new MockOracle(1e18);
        MiniLendingMarket m = new MiniLendingMarket(loan, coll, oracle, LLTV);

        _runBadDebt(m, loan, coll, oracle);

        assertTrue(_solvent(m, loan), "correct market must stay solvent after socialising bad debt");
        assertEq(m.borrowAssetsOf(borrower), 0, "fully-liquidated borrower must carry no debt");
    }

    function test_brokenMarket_badDebt_breaksSolvency() public {
        MockERC20 loan = new MockERC20();
        MockERC20 coll = new MockERC20();
        MockOracle oracle = new MockOracle(1e18);
        BrokenLendingMarket m = new BrokenLendingMarket(loan, coll, oracle, LLTV);

        _runBadDebt(m, loan, coll, oracle);

        // The invariant expression is violated: the market is silently insolvent.
        assertFalse(_solvent(m, loan), "expected the un-socialised bad debt to break solvency");
        assertLt(
            loan.balanceOf(address(m)) + m.totalBorrowAssets(),
            m.totalSupplyAssets(),
            "loanBalance + totalBorrowAssets should fall below totalSupplyAssets"
        );
    }
}
