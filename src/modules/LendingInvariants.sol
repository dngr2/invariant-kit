// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

/// @notice Minimal ERC20 surface the harness needs to read balances and fund actors.
interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Mintable variant used only in tests to fund the fuzz actors.
interface IERC20Mintable is IERC20Like {
    function mint(address to, uint256 amount) external;
}

/// @notice Over-collateralised lending-market surface (Morpho-style single pair).
///         A real isolated or pooled market is a superset of this — point the
///         harness at your own market.
interface ILendingMarket {
    function loanToken() external view returns (address);
    function collateralToken() external view returns (address);
    function totalSupplyAssets() external view returns (uint256);
    function totalBorrowAssets() external view returns (uint256);
    function totalCollateral() external view returns (uint256);
    function supplyAssetsOf(address) external view returns (uint256);
    function borrowAssetsOf(address) external view returns (uint256);
    function collateralOf(address) external view returns (uint256);
    function supply(uint256 assets) external;
    function withdraw(uint256 assets) external;
    function supplyCollateral(uint256 amount) external;
    function withdrawCollateral(uint256 amount) external;
    function borrow(uint256 assets) external;
    function repay(uint256 assets) external;
    function liquidate(address borrower) external;
}

/// @notice A settable price source. In production this is your oracle; in the
///         harness it is a mock the fuzzer moves to create liquidations.
interface ISettableOracle {
    function setPrice(uint256 price) external;
    function price() external view returns (uint256);
}

/// @notice Bounded random actor set that supplies/borrows/repays, moves the
///         oracle and liquidates. The price moves are what create underwater
///         positions and bad debt — the state a correct market must still keep
///         solvent.
contract LendingHandler is Test {
    ILendingMarket public immutable market;
    IERC20Mintable public immutable loanToken;
    IERC20Mintable public immutable collateralToken;
    ISettableOracle public immutable oracle;

    uint256 internal constant NUM_ACTORS = 4;
    address[] public actors;

    constructor(ILendingMarket m, IERC20Mintable loan, IERC20Mintable coll, ISettableOracle o) {
        market = m;
        loanToken = loan;
        collateralToken = coll;
        oracle = o;
        for (uint256 i; i < NUM_ACTORS; i++) {
            address a = makeAddr(string.concat("ik_lender_", vm.toString(i)));
            actors.push(a);
            loan.mint(a, 1e30);
            coll.mint(a, 1e30);
            vm.startPrank(a);
            loan.approve(address(m), type(uint256).max);
            coll.approve(address(m), type(uint256).max);
            vm.stopPrank();
        }
        // Seed liquidity so borrows can happen from block one.
        vm.prank(actors[0]);
        m.supply(1_000_000e18);
    }

    function numActors() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function supply(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        amount = bound(amount, 0, loanToken.balanceOf(a));
        if (amount == 0) return;
        vm.prank(a);
        market.supply(amount);
    }

    function withdraw(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        uint256 idle = loanToken.balanceOf(address(market));
        uint256 cap = market.supplyAssetsOf(a);
        if (idle < cap) cap = idle;
        amount = bound(amount, 0, cap);
        if (amount == 0) return;
        vm.prank(a);
        try market.withdraw(amount) {} catch {}
    }

    function addCollateral(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        amount = bound(amount, 0, collateralToken.balanceOf(a));
        if (amount == 0) return;
        vm.prank(a);
        market.supplyCollateral(amount);
    }

    function removeCollateral(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        amount = bound(amount, 0, market.collateralOf(a));
        if (amount == 0) return;
        vm.prank(a);
        try market.withdrawCollateral(amount) {} catch {}
    }

    function borrow(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        amount = bound(amount, 0, loanToken.balanceOf(address(market)));
        if (amount == 0) return;
        vm.prank(a);
        try market.borrow(amount) {} catch {}
    }

    function repay(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        uint256 cap = market.borrowAssetsOf(a);
        uint256 bal = loanToken.balanceOf(a);
        if (bal < cap) cap = bal;
        amount = bound(amount, 0, cap);
        if (amount == 0) return;
        vm.prank(a);
        market.repay(amount);
    }

    function setPrice(uint256 price) external {
        oracle.setPrice(bound(price, 0.2e18, 2e18));
    }

    function liquidate(uint256 borrowerSeed, uint256 liquidatorSeed) external {
        address borrower = _actor(borrowerSeed);
        address liquidator = _actor(liquidatorSeed);
        vm.prank(liquidator);
        try market.liquidate(borrower) {} catch {}
    }
}

/// @notice Drop-in invariant harness for an over-collateralised lending market.
///         Extend it, implement {_setUpMarket} to deploy/return your market, its
///         (mintable, in tests) loan + collateral tokens and a settable oracle,
///         and Foundry fuzzes the core solvency/accounting properties under
///         random borrow/repay/price/liquidate sequences.
///
///         The properties catch the two ways lending markets quietly go
///         insolvent: idle liquidity going negative, and bad debt that is not
///         socialised to suppliers (left on the books as phantom, uncollectable
///         debt).
abstract contract LendingInvariantHarness is StdInvariant, Test {
    ILendingMarket internal market;
    LendingHandler internal handler;

    /// @dev Teams override: deploy/return the market under test, its loan and
    ///      collateral tokens, and a settable oracle.
    function _setUpMarket()
        internal
        virtual
        returns (ILendingMarket market_, IERC20Mintable loan_, IERC20Mintable coll_, ISettableOracle oracle_);

    function setUp() public virtual {
        (ILendingMarket m, IERC20Mintable loan, IERC20Mintable coll, ISettableOracle o) = _setUpMarket();
        market = m;
        handler = new LendingHandler(m, loan, coll, o);
        targetContract(address(handler));
    }

    function _loanBalance() internal view returns (uint256) {
        return IERC20Like(market.loanToken()).balanceOf(address(market));
    }

    /// Idle liquidity is never negative: the loan tokens still in the market plus
    /// what has been lent out must always back at least what suppliers are owed.
    /// A market that fails to socialise bad debt leaves `totalSupplyAssets` too
    /// high and trips this.
    function invariant_idleLiquidityNonNegative() public view {
        assertGe(
            _loanBalance() + market.totalBorrowAssets(),
            market.totalSupplyAssets(),
            "INSOLVENT: loanBalance + totalBorrowAssets < totalSupplyAssets (unsocialised bad debt)"
        );
    }

    /// The market can never have lent out more than was supplied.
    function invariant_neverOverLent() public view {
        assertLe(
            market.totalBorrowAssets(), market.totalSupplyAssets(), "OVER-LENT: totalBorrowAssets > totalSupplyAssets"
        );
    }

    /// A fully-liquidated (zero-collateral) borrower must carry zero debt: bad
    /// debt is socialised, not left on the books as phantom, uncollectable debt.
    function invariant_noPhantomBadDebt() public view {
        uint256 n = handler.numActors();
        for (uint256 i; i < n; i++) {
            address a = handler.actors(i);
            if (market.collateralOf(a) == 0) {
                assertEq(
                    market.borrowAssetsOf(a),
                    0,
                    "PHANTOM DEBT: zero-collateral borrower still carries debt (bad debt not socialised)"
                );
            }
        }
    }

    /// Physical collateral held must back the sum of tracked collateral.
    function invariant_collateralBacking() public view {
        assertGe(
            IERC20Like(market.collateralToken()).balanceOf(address(market)),
            market.totalCollateral(),
            "COLLATERAL SHORTFALL: held collateral < tracked collateral"
        );
    }
}
