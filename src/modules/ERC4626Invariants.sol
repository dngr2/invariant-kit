// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

/// @notice Standard ERC-4626 subset used by the kit. Any real ERC-4626 vault
///         satisfies this, so point the harness at your own vault.
interface IERC4626Like {
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
}

/// @notice Minimal mintable ERC20 the harness uses to fund the fuzz actor.
interface IERC20Mint {
    function mint(address to, uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @notice Bounded random deposit/redeem/donate actor that Foundry drives.
///         `donate` (direct transfer to the vault) is included on purpose — it
///         is the inflation/first-depositor attack vector, and a correct vault's
///         invariants must survive it.
contract ERC4626Handler is Test {
    IERC4626Like public immutable vault;
    IERC20Mint public immutable asset;
    uint256 public totalDeposited;
    uint256 public totalWithdrawn;

    constructor(IERC4626Like v, IERC20Mint a) {
        vault = v;
        asset = a;
        a.mint(address(this), 1e30);
        a.approve(address(v), type(uint256).max);
    }

    function deposit(uint256 amount) external {
        amount = bound(amount, 0, asset.balanceOf(address(this)));
        if (amount == 0) return;
        vault.deposit(amount, address(this));
        totalDeposited += amount;
    }

    function redeem(uint256 shares) external {
        shares = bound(shares, 0, vault.balanceOf(address(this)));
        if (shares == 0) return;
        totalWithdrawn += vault.redeem(shares, address(this), address(this));
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 0, asset.balanceOf(address(this)) / 2);
        if (amount == 0) return;
        asset.transfer(address(vault), amount);
    }
}

/// @notice Drop-in ERC-4626 invariant harness. Extend it, implement
///         {_setUpVault} to return your vault + its (mintable, in tests) asset,
///         and Foundry fuzzes the core solvency/accounting properties for you.
///
///         forge test  (with [invariant] runs/depth in foundry.toml)
abstract contract ERC4626InvariantHarness is StdInvariant, Test {
    IERC4626Like internal vault;
    ERC4626Handler internal handler;

    /// @dev Teams override: deploy/return the vault under test and its asset.
    function _setUpVault() internal virtual returns (IERC4626Like vault_, IERC20Mint asset_);

    function setUp() public virtual {
        (IERC4626Like v, IERC20Mint a) = _setUpVault();
        vault = v;
        handler = new ERC4626Handler(v, a);
        targetContract(address(handler));
    }

    /// Shares must never claim more assets than the vault actually holds.
    function invariant_solvency() public view {
        assertLe(
            vault.convertToAssets(vault.totalSupply()),
            vault.totalAssets() + 1,
            "INSOLVENT: outstanding shares convert to more than totalAssets"
        );
    }

    /// A deposit->redeem round trip must not manufacture value (rounding must
    /// favour the vault, not the redeemer).
    function invariant_roundTripNoValueCreation() public view {
        uint256 probe = 1e18;
        uint256 shares = vault.previewDeposit(probe);
        assertLe(vault.previewRedeem(shares), probe, "ROUND-TRIP GAIN: previewRedeem(previewDeposit(x)) > x");
    }
}
