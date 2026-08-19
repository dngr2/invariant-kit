// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal ERC20 for tests.
contract MockERC20 {
    string public name = "Mock";
    string public symbol = "MOCK";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

/// @dev Standard-ERC4626 subset both reference vaults implement, so `invariant-kit`
///      modules run against any real ERC-4626 vault (a superset of this).
abstract contract MinimalERC4626 {
    MockERC20 public immutable assetToken;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(MockERC20 a) {
        assetToken = a;
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    function totalAssets() public view returns (uint256) {
        return assetToken.balanceOf(address(this));
    }

    function convertToShares(uint256 assets) public view virtual returns (uint256);
    function convertToAssets(uint256 shares) public view virtual returns (uint256);

    function previewDeposit(uint256 assets) public view returns (uint256) {
        return convertToShares(assets);
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return convertToAssets(shares);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = convertToShares(assets);
        assetToken.transferFrom(msg.sender, address(this), assets);
        totalSupply += shares;
        balanceOf[receiver] += shares;
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        assets = convertToAssets(shares);
        balanceOf[owner] -= shares;
        totalSupply -= shares;
        assetToken.transfer(receiver, assets);
    }
}

/// @title NaiveVault (VULNERABLE — first-depositor inflation)
/// @notice Prices shares against the raw balance with no virtual offset, so a
///         direct donation inflates the share price and a later depositor's
///         shares round down to zero. Nothing reverts.
contract NaiveVault is MinimalERC4626 {
    constructor(MockERC20 a) MinimalERC4626(a) {}

    function convertToShares(uint256 assets) public view override returns (uint256) {
        uint256 supply = totalSupply;
        return supply == 0 ? assets : (assets * supply) / totalAssets();
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        uint256 supply = totalSupply;
        return supply == 0 ? shares : (shares * totalAssets()) / supply;
    }
}

/// @title SafeVault (FIXED — OZ-style virtual shares/assets)
/// @notice decimalsOffset = 6: convertToShares = assets*(supply+1e6)/(assets_+1),
///         convertToAssets = shares*(assets_+1)/(supply+1e6). Keeps a victim's
///         rounding loss negligible and makes inflation unprofitable.
contract SafeVault is MinimalERC4626 {
    uint256 private constant OFFSET = 1e6;

    constructor(MockERC20 a) MinimalERC4626(a) {}

    function convertToShares(uint256 assets) public view override returns (uint256) {
        return (assets * (totalSupply + OFFSET)) / (totalAssets() + 1);
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        return (shares * (totalAssets() + 1)) / (totalSupply + OFFSET);
    }
}
