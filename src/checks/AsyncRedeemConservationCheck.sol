// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

/// @notice Minimal ERC20 balance read used by the check.
interface IERC20Bal {
    function balanceOf(address) external view returns (uint256);
}

/// @notice ERC-7540-style async-redeem vault surface. A redemption is requested,
///         later fulfilled (assets are reserved for it), then claimed. Between
///         fulfilment and claim the vault owes those assets to the controller and
///         must keep them set aside.
interface IAsyncRedeemVault {
    function asset() external view returns (address);
    /// @notice Total assets reserved for fulfilled-but-unclaimed redemptions.
    function totalReserved() external view returns (uint256);
    /// @notice Assets a single controller can claim right now.
    function claimableRedeemAssets(address controller) external view returns (uint256);
}

/// @notice Stateless conservation check for an async-redeem vault. Assets owed to
///         fulfilled redemptions must be both fully backed and fully accounted:
///           1. reserved assets never exceed the assets the vault actually holds;
///           2. the per-controller claimable amounts sum to exactly the reserve.
///
///         A vault that fulfils a redemption but drops the reserve bookkeeping
///         leaks the claim: the sum of what controllers can withdraw no longer
///         matches (or is no longer backed by) the reserve. Extend this in a test
///         and call {assertReserveConserved} with the vault and the set of
///         controllers you want covered.
abstract contract AsyncRedeemConservationCheck is Test {
    function _sumClaimable(IAsyncRedeemVault vault, address[] memory controllers) internal view returns (uint256 sum) {
        for (uint256 i; i < controllers.length; i++) {
            sum += vault.claimableRedeemAssets(controllers[i]);
        }
    }

    /// @dev Passes iff the reserve is backed by held assets and equals the sum of
    ///      every controller's claimable amount.
    function assertReserveConserved(IAsyncRedeemVault vault, address[] memory controllers) internal view {
        uint256 reserved = vault.totalReserved();
        assertLe(
            reserved,
            IERC20Bal(vault.asset()).balanceOf(address(vault)),
            "UNDERBACKED: reserved assets exceed assets the vault holds"
        );
        assertEq(
            _sumClaimable(vault, controllers),
            reserved,
            "RESERVE LEAK: sum of per-controller claimable != totalReserved"
        );
    }
}
