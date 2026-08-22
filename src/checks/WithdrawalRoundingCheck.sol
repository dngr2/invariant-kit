// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20Mint} from "../modules/ERC4626Invariants.sol";

/// @notice The asset-denominated withdraw surface of an ERC-4626-style vault.
interface IWithdrawVault {
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

/// @notice Reusable withdrawal-rounding-direction exploit check. Extend it in a
///         test and call {assertWithdrawRoundingFavorsVault} against your vault to
///         get a concrete pass/fail (a failing transaction if vulnerable).
///
///         The bug: `withdraw(assets)` computes the share cost with the SAME
///         floor-rounding used for deposits. Once the share price drifts above
///         1:1 (any yield, any donation), a small withdrawal rounds the share cost
///         down to ZERO — the assets leave the vault and no shares are burned.
///         Repeat and the vault is drained one dust-withdrawal at a time. ERC-4626
///         requires `previewWithdraw` to round UP for exactly this reason.
///
///         The check seeds a vault to an above-1:1 price and asserts that
///         withdrawing one unit of assets always costs at least one share.
abstract contract WithdrawalRoundingCheck is Test {
    /// @dev Seeds the vault to an above-1:1 share price, then asserts that a
    ///      1-unit asset withdrawal burns a non-zero number of shares. A vault
    ///      that rounds the share cost down fails here.
    function assertWithdrawRoundingFavorsVault(IWithdrawVault vault, IERC20Mint asset) internal {
        address seeder = makeAddr("ik_round_seeder");

        // Seed 100 assets -> 100 shares (1:1), then donate 1 asset so the price
        // drifts to 101/100 and share-cost rounding starts to bite.
        asset.mint(seeder, 100);
        vm.startPrank(seeder);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(100, seeder);
        vm.stopPrank();

        asset.mint(address(this), 1);
        asset.transfer(address(vault), 1); // donation: assets=101, supply=100

        // Precondition: the price really is above 1:1, so rounding direction matters.
        require(vault.totalAssets() > vault.totalSupply() && vault.totalSupply() > 0, "SETUP: price not above 1:1");

        uint256 shareCost = vault.previewWithdraw(1);
        assertGt(
            shareCost,
            0,
            "WITHDRAW ROUNDING: withdrawing 1 asset burns 0 shares (rounds down) - assets leave the vault for free"
        );
    }
}
