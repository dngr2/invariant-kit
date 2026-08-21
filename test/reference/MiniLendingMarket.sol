// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC20} from "./ReferenceVaults.sol";

/// @notice Settable price oracle: `price` is the collateral price denominated in
///         the loan token, WAD-scaled (1e18 == 1 loan token per collateral unit).
contract MockOracle {
    uint256 public price;

    constructor(uint256 p) {
        price = p;
    }

    function setPrice(uint256 p) external {
        price = p;
    }
}

/// @title LendingMarketBase — a tiny Morpho-style isolated lending pair
/// @notice One loan token, one collateral token, one oracle, no interest. Enough
///         to exercise the whole solvency surface: supply/withdraw liquidity,
///         post/withdraw collateral, borrow against it, repay, and liquidate an
///         underwater position — including the bad-debt path where seizing all
///         collateral does not cover the debt.
///
///         The only behaviour that differs between the correct and the broken
///         reference is {_realizeBadDebt}; everything else is shared so the bug
///         is isolated to one override.
abstract contract LendingMarketBase {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant LIF = 1.05e18; // liquidation incentive: 5% bonus

    MockERC20 public immutable loanToken;
    MockERC20 public immutable collateralToken;
    MockOracle public immutable oracle;
    uint256 public immutable lltv; // max loan-to-value, WAD

    uint256 public totalSupplyAssets;
    uint256 public totalBorrowAssets;
    uint256 public totalCollateral;

    mapping(address => uint256) public supplyAssetsOf;
    mapping(address => uint256) public borrowAssetsOf;
    mapping(address => uint256) public collateralOf;

    constructor(MockERC20 loan, MockERC20 coll, MockOracle o, uint256 lltv_) {
        loanToken = loan;
        collateralToken = coll;
        oracle = o;
        lltv = lltv_;
    }

    // --- liquidity ---

    function supply(uint256 assets) external {
        loanToken.transferFrom(msg.sender, address(this), assets);
        totalSupplyAssets += assets;
        supplyAssetsOf[msg.sender] += assets;
    }

    function withdraw(uint256 assets) external {
        require(assets <= supplyAssetsOf[msg.sender], "insufficient supply");
        require(loanToken.balanceOf(address(this)) >= assets, "insufficient liquidity");
        supplyAssetsOf[msg.sender] -= assets;
        totalSupplyAssets -= assets;
        loanToken.transfer(msg.sender, assets);
    }

    // --- collateral ---

    function supplyCollateral(uint256 amount) external {
        collateralToken.transferFrom(msg.sender, address(this), amount);
        collateralOf[msg.sender] += amount;
        totalCollateral += amount;
    }

    function withdrawCollateral(uint256 amount) external {
        require(amount <= collateralOf[msg.sender], "insufficient collateral");
        collateralOf[msg.sender] -= amount;
        totalCollateral -= amount;
        require(_isHealthy(msg.sender), "unhealthy");
        collateralToken.transfer(msg.sender, amount);
    }

    // --- borrowing ---

    function borrow(uint256 assets) external {
        require(loanToken.balanceOf(address(this)) >= assets, "insufficient liquidity");
        borrowAssetsOf[msg.sender] += assets;
        totalBorrowAssets += assets;
        require(_isHealthy(msg.sender), "unhealthy");
        loanToken.transfer(msg.sender, assets);
    }

    function repay(uint256 assets) external {
        uint256 debt = borrowAssetsOf[msg.sender];
        if (assets > debt) assets = debt;
        loanToken.transferFrom(msg.sender, address(this), assets);
        borrowAssetsOf[msg.sender] -= assets;
        totalBorrowAssets -= assets;
    }

    // --- liquidation ---

    /// @notice Seize all of an underwater borrower's collateral, repaying as much
    ///         debt as its (discounted) value covers. Any debt left after the
    ///         collateral is gone is bad debt, handled by {_realizeBadDebt}.
    function liquidate(address borrower) external {
        require(!_isHealthy(borrower), "healthy");

        uint256 collValue = collateralOf[borrower] * oracle.price() / WAD;
        uint256 repaid = collValue * WAD / LIF; // liquidator repays discounted, keeps the bonus
        uint256 debt = borrowAssetsOf[borrower];
        if (repaid > debt) repaid = debt;

        loanToken.transferFrom(msg.sender, address(this), repaid);
        borrowAssetsOf[borrower] -= repaid;
        totalBorrowAssets -= repaid;

        uint256 seized = collateralOf[borrower];
        collateralOf[borrower] = 0;
        totalCollateral -= seized;
        collateralToken.transfer(msg.sender, seized);

        uint256 badDebt = borrowAssetsOf[borrower];
        if (badDebt > 0) _realizeBadDebt(borrower, badDebt);
    }

    /// @dev How the market absorbs bad debt once a borrower's collateral is gone.
    function _realizeBadDebt(address borrower, uint256 badDebt) internal virtual;

    // --- views ---

    function _maxBorrow(address user) internal view returns (uint256) {
        uint256 collValue = collateralOf[user] * oracle.price() / WAD;
        return collValue * lltv / WAD;
    }

    function _isHealthy(address user) internal view returns (bool) {
        return borrowAssetsOf[user] <= _maxBorrow(user);
    }
}

/// @title MiniLendingMarket (CORRECT)
/// @notice Socialises bad debt: it writes the uncollectable debt off the
///         borrower AND takes the matching loss on the supply side, so idle
///         liquidity stays consistent and no phantom debt is left behind.
contract MiniLendingMarket is LendingMarketBase {
    constructor(MockERC20 loan, MockERC20 coll, MockOracle o, uint256 lltv_) LendingMarketBase(loan, coll, o, lltv_) {}

    function _realizeBadDebt(address borrower, uint256 badDebt) internal override {
        borrowAssetsOf[borrower] -= badDebt;
        totalBorrowAssets -= badDebt;
        totalSupplyAssets -= badDebt; // suppliers eat the loss
    }
}

/// @title BrokenLendingMarket (VULNERABLE — bad debt not socialised)
/// @notice Clears the borrower's uncollectable debt but FORGETS to take the loss
///         on the supply side. `totalSupplyAssets` stays too high, so suppliers
///         collectively believe they can withdraw more than the market holds —
///         the market is silently insolvent. Nothing reverts.
///
///         `LendingInvariantHarness.invariant_idleLiquidityNonNegative` catches
///         it: after a bad-debt liquidation, `loanBalance + totalBorrowAssets`
///         drops below `totalSupplyAssets`.
contract BrokenLendingMarket is LendingMarketBase {
    constructor(MockERC20 loan, MockERC20 coll, MockOracle o, uint256 lltv_) LendingMarketBase(loan, coll, o, lltv_) {}

    function _realizeBadDebt(address borrower, uint256 badDebt) internal override {
        borrowAssetsOf[borrower] -= badDebt;
        totalBorrowAssets -= badDebt;
        // BUG: forgets `totalSupplyAssets -= badDebt`, so the loss is never
        // socialised and the market's books overstate what it can pay out.
    }
}
