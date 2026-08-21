// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC20} from "./ReferenceVaults.sol";

/// @title AsyncRedeemBase — a tiny ERC-7540-style async-redeem vault
/// @notice Shares are 1:1 with assets (no yield) to keep the focus on the
///         redemption lifecycle: deposit, requestRedeem (shares escrowed),
///         fulfillRedeem (shares burned, assets reserved), claimRedeem (reserved
///         assets paid out). The only difference between the correct and broken
///         references is whether {fulfillRedeem} keeps the reserve accounting.
abstract contract AsyncRedeemBase {
    MockERC20 public immutable assetToken;

    mapping(address => uint256) public shares;
    mapping(address => uint256) public pendingRedeemShares;
    mapping(address => uint256) public claimableRedeemAssets;
    uint256 public totalReserved;

    constructor(MockERC20 a) {
        assetToken = a;
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    function deposit(uint256 assets) external {
        assetToken.transferFrom(msg.sender, address(this), assets);
        shares[msg.sender] += assets; // 1:1
    }

    function requestRedeem(uint256 amount, address controller) external {
        shares[msg.sender] -= amount;
        pendingRedeemShares[controller] += amount;
    }

    /// @notice Convert a controller's pending shares into a claimable asset
    ///         balance. The assets stay in the vault, reserved for the claim.
    function fulfillRedeem(address controller) external virtual;

    function claimRedeem(address controller) external virtual {
        uint256 assets = claimableRedeemAssets[controller];
        claimableRedeemAssets[controller] = 0;
        totalReserved -= assets;
        assetToken.transfer(controller, assets);
    }
}

/// @title AsyncRedeemVault (CORRECT)
/// @notice Fulfilment reserves the assets: it credits the controller's claimable
///         balance AND adds to `totalReserved`, so the reserve always equals the
///         sum of outstanding claims and is backed by held assets.
contract AsyncRedeemVault is AsyncRedeemBase {
    constructor(MockERC20 a) AsyncRedeemBase(a) {}

    function fulfillRedeem(address controller) external override {
        uint256 amount = pendingRedeemShares[controller];
        pendingRedeemShares[controller] = 0;
        claimableRedeemAssets[controller] += amount; // 1:1
        totalReserved += amount;
    }
}

/// @title BrokenAsyncRedeemVault (VULNERABLE — reserve accounting dropped)
/// @notice Fulfilment credits the controller's claimable balance but FORGETS to
///         add to `totalReserved`. The vault now owes more than it has reserved:
///         the sum of what controllers can claim no longer equals `totalReserved`
///         (and later claims underflow / are unbacked).
///
///         `AsyncRedeemConservationCheck.assertReserveConserved` catches it: the
///         per-controller claimable amounts no longer sum to the reserve.
contract BrokenAsyncRedeemVault is AsyncRedeemBase {
    constructor(MockERC20 a) AsyncRedeemBase(a) {}

    function fulfillRedeem(address controller) external override {
        uint256 amount = pendingRedeemShares[controller];
        pendingRedeemShares[controller] = 0;
        claimableRedeemAssets[controller] += amount;
        // BUG: forgets `totalReserved += amount` — the reserve is never recorded.
    }

    function claimRedeem(address controller) external override {
        // Mirror the dropped accounting so a claim does not underflow.
        uint256 assets = claimableRedeemAssets[controller];
        claimableRedeemAssets[controller] = 0;
        assetToken.transfer(controller, assets);
    }
}
