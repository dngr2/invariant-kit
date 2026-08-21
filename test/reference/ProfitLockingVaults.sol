// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC20} from "./ReferenceVaults.sol";

/// @title ProfitLockingBase — shared ERC-4626 share machinery for the references
/// @notice A gain reported to the vault should raise the price per share
///         *gradually*, not in the block it is reported — otherwise anyone can
///         sandwich the report (deposit just before, redeem just after) and
///         steal the profit from existing holders. The mechanism is Yearn-V3's:
///         on profit the vault mints locked shares to itself so the price per
///         share is unchanged, then unlocks (burns) them linearly over a window.
///
///         `totalSupply()` counts still-locked shares but excludes the portion
///         that has already vested and is pending burn — as that grows, supply
///         falls and the price per share rises. All the reference vaults share
///         this; only {report} and the unlock schedule differ.
abstract contract ProfitLockingBase {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RATE_PRECISION = 1e18;
    uint256 internal constant MAX_UNLOCK = 7 days;

    MockERC20 public immutable assetToken;

    uint256 internal rawSupply; // full ERC20 supply, including locked shares
    mapping(address => uint256) public balanceOf;

    // unlock schedule for the currently locked profit
    uint256 public profitUnlockingRate; // shares/sec * RATE_PRECISION
    uint256 public fullProfitUnlockDate;
    uint256 public lastProfitUpdate;

    constructor(MockERC20 a) {
        assetToken = a;
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    function totalAssets() public view returns (uint256) {
        return assetToken.balanceOf(address(this));
    }

    /// @dev Shares that have vested since the last update and are pending burn.
    function _unlockedSharesView() internal view virtual returns (uint256) {
        uint256 self = balanceOf[address(this)];
        if (fullProfitUnlockDate > block.timestamp && profitUnlockingRate > 0) {
            uint256 unlocked = profitUnlockingRate * (block.timestamp - lastProfitUpdate) / RATE_PRECISION;
            return unlocked > self ? self : unlocked;
        }
        return self; // schedule elapsed (or none): all self-held shares are unlocked
    }

    function unlockedShares() public view returns (uint256) {
        return _unlockedSharesView();
    }

    function lockedShares() public view returns (uint256) {
        return balanceOf[address(this)] - _unlockedSharesView();
    }

    /// @notice Effective supply: excludes vested-but-not-yet-burned profit shares.
    function totalSupply() public view returns (uint256) {
        return rawSupply - _unlockedSharesView();
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 ts = totalSupply();
        uint256 ta = totalAssets();
        return (ts == 0 || ta == 0) ? assets : assets * ts / ta;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 ts = totalSupply();
        return ts == 0 ? shares : shares * totalAssets() / ts;
    }

    function pricePerShare() external view returns (uint256) {
        uint256 ts = totalSupply();
        return ts == 0 ? WAD : totalAssets() * WAD / ts;
    }

    function _mint(address to, uint256 shares) internal {
        rawSupply += shares;
        balanceOf[to] += shares;
    }

    function _burn(address from, uint256 shares) internal {
        rawSupply -= shares;
        balanceOf[from] -= shares;
    }

    /// @dev Physically burn shares that have vested and advance the schedule.
    function _accrue() internal virtual {}

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        _accrue();
        shares = convertToShares(assets);
        assetToken.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        _accrue();
        assets = convertToAssets(shares);
        _burn(owner, shares);
        assetToken.transfer(receiver, assets);
    }

    function report(uint256 gain) external virtual;
}

/// @title ProfitLockingVault (CORRECT)
/// @notice On profit it mints locked shares to itself so the price per share is
///         unchanged in-block, then unlocks them linearly over MAX_UNLOCK.
contract ProfitLockingVault is ProfitLockingBase {
    constructor(MockERC20 a) ProfitLockingBase(a) {}

    function _accrue() internal override {
        uint256 unlocked = _unlockedSharesView();
        if (unlocked > 0) _burn(address(this), unlocked);
        if (block.timestamp >= fullProfitUnlockDate) {
            profitUnlockingRate = 0;
            fullProfitUnlockDate = 0;
        }
        lastProfitUpdate = block.timestamp;
    }

    function report(uint256 gain) external override {
        _accrue();
        assetToken.transferFrom(msg.sender, address(this), gain);
        if (gain == 0) return;

        uint256 ts = totalSupply();
        uint256 taOld = totalAssets() - gain;
        // Mint enough locked shares that the price per share does not rise now.
        // Round the mint UP so any dust rounding can only lower PPS in-block,
        // never raise it — the anti-sandwich guarantee holds at any supply size.
        uint256 newLocked = (ts == 0 || taOld == 0) ? 0 : (gain * ts + taOld - 1) / taOld;
        if (newLocked > 0) {
            _mint(address(this), newLocked);
            uint256 locked = balanceOf[address(this)];
            profitUnlockingRate = locked * RATE_PRECISION / MAX_UNLOCK;
            fullProfitUnlockDate = block.timestamp + MAX_UNLOCK;
            lastProfitUpdate = block.timestamp;
        }
    }
}

/// @title BrokenProfitLockingVault (VULNERABLE — instant profit credit)
/// @notice Reports profit by simply taking the assets in. It mints no locked
///         shares, so `totalAssets` jumps while `totalSupply` does not and the
///         price per share leaps in the same block — a depositor who front-runs
///         the report and redeems right after pockets the gain.
///
///         `ProfitLockingHandler.report` catches it: the price per share is not
///         allowed to move in the block a gain is reported.
contract BrokenProfitLockingVault is ProfitLockingBase {
    constructor(MockERC20 a) ProfitLockingBase(a) {}

    function _unlockedSharesView() internal view override returns (uint256) {
        return 0; // never locks anything
    }

    function report(uint256 gain) external override {
        // BUG: profit credited straight to the price per share, no locking.
        assetToken.transferFrom(msg.sender, address(this), gain);
    }
}
