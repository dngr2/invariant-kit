// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC20} from "./ReferenceVaults.sol";

/// @dev A minimal ERC-4626-style vault with the asset-denominated withdraw path.
///      `withdraw(assets)` must burn ENOUGH shares to cover the assets leaving —
///      i.e. the share count is rounded UP, in the vault's favour. The two
///      variants differ only in that rounding direction.
abstract contract RoundingVaultBase {
    MockERC20 public immutable asset;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(MockERC20 a) {
        asset = a;
    }

    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function _sharesForAssets(uint256 assets, bool roundUp) internal view returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) return assets;
        uint256 num = assets * supply;
        uint256 den = totalAssets();
        return roundUp ? (num + den - 1) / den : num / den;
    }

    // deposit grants shares rounded DOWN (vault-favourable): correct in both variants.
    function previewDeposit(uint256 assets) public view returns (uint256) {
        return _sharesForAssets(assets, false);
    }

    // The variant-specific direction — this is the bug surface.
    function previewWithdraw(uint256 assets) public view virtual returns (uint256);

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = previewDeposit(assets);
        asset.transferFrom(msg.sender, address(this), assets);
        totalSupply += shares;
        balanceOf[receiver] += shares;
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        shares = previewWithdraw(assets);
        balanceOf[owner] -= shares; // reverts if the owner lacks the shares
        totalSupply -= shares;
        asset.transfer(receiver, assets);
    }
}

/// @dev CORRECT: `withdraw` rounds the share cost UP, so pulling any non-zero
///      amount of assets always burns at least one share.
contract CorrectRoundingVault is RoundingVaultBase {
    constructor(MockERC20 a) RoundingVaultBase(a) {}

    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        return _sharesForAssets(assets, true);
    }
}

/// @dev BROKEN: `withdraw` rounds the share cost DOWN. When the share price has
///      drifted above 1:1, a small withdrawal rounds to ZERO shares burned while
///      the assets still leave — free value, repeatable until the vault is drained.
contract WrongWithdrawRoundingVault is RoundingVaultBase {
    constructor(MockERC20 a) RoundingVaultBase(a) {}

    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        return _sharesForAssets(assets, false);
    }
}
