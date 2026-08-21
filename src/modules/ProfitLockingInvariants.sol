// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

/// @notice Minimal mintable ERC20 the harness uses to fund actors and profit.
interface IERC20Mint {
    function mint(address to, uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @notice Profit-locking ERC-4626 allocator surface (Yearn-V3 style). A gain is
///         reported via {report}, which drips into the price per share over an
///         unlock window instead of crediting it instantly.
interface IProfitLockingVault {
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function pricePerShare() external view returns (uint256);
    function lockedShares() external view returns (uint256);
    function unlockedShares() external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
    function report(uint256 gain) external;
}

/// @notice Bounded random actor set that deposits, redeems, reports profit and
///         lets time pass. Two properties are enforced inline, because they are
///         statements about a *transition*, not a static state:
///           - reporting a gain must not move the price per share in the same
///             block (the anti-sandwich property);
///           - the price per share must never fall between actions (there is no
///             loss action here, so it must be monotonic non-decreasing).
contract ProfitLockingHandler is Test {
    IProfitLockingVault public immutable vault;
    IERC20Mint public immutable asset;

    uint256 internal constant NUM_ACTORS = 3;
    uint256 internal constant PPS_TOL = 1e6; // wei of a WAD-scaled price per share
    address[] public actors;
    uint256 public lastPps;

    constructor(IProfitLockingVault v, IERC20Mint a) {
        vault = v;
        asset = a;
        for (uint256 i; i < NUM_ACTORS; i++) {
            address actor = makeAddr(string.concat("ik_alloc_", vm.toString(i)));
            actors.push(actor);
            a.mint(actor, 1e30);
            vm.prank(actor);
            a.approve(address(v), type(uint256).max);
        }
        // Seed a first deposit held by the handler itself (never redeemed) so the
        // vault is always priced and effective supply never collapses to dust.
        a.mint(address(this), 1_000e18);
        a.approve(address(v), type(uint256).max);
        v.deposit(1_000e18, address(this));
        lastPps = v.pricePerShare();
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _checkMonotonic() internal {
        uint256 p = vault.pricePerShare();
        assertGe(p + PPS_TOL, lastPps, "PPS DROPPED without a realised loss");
        lastPps = p;
    }

    function deposit(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        amount = bound(amount, 0, asset.balanceOf(a));
        if (amount == 0) return;
        vm.prank(a);
        vault.deposit(amount, a);
        _checkMonotonic();
    }

    function redeem(uint256 seed, uint256 shares) external {
        address a = _actor(seed);
        shares = bound(shares, 0, vault.balanceOf(a));
        if (shares == 0) return;
        vm.prank(a);
        vault.redeem(shares, a, a);
        _checkMonotonic();
    }

    function report(uint256 gain) external {
        gain = bound(gain, 0, 1e24);
        uint256 before = vault.pricePerShare();
        asset.mint(address(this), gain);
        asset.approve(address(vault), gain);
        vault.report(gain);
        uint256 afterPps = vault.pricePerShare();
        assertLe(afterPps, before + PPS_TOL, "ANTI-SANDWICH: PPS jumped in the same block a gain was reported");
        lastPps = afterPps;
    }

    function passTime(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 10 days));
        _checkMonotonic();
    }
}

/// @notice Drop-in invariant harness for a profit-locking ERC-4626 allocator.
///         Extend it, implement {_setUpVault} to return your vault + its
///         (mintable, in tests) asset, and Foundry fuzzes the solvency and
///         locked-share accounting while the handler enforces the anti-sandwich
///         and PPS-monotonicity transition properties.
abstract contract ProfitLockingInvariantHarness is StdInvariant, Test {
    IProfitLockingVault internal vault;
    ProfitLockingHandler internal handler;

    /// @dev Teams override: deploy/return the vault under test and its asset.
    function _setUpVault() internal virtual returns (IProfitLockingVault vault_, IERC20Mint asset_);

    function setUp() public virtual {
        (IProfitLockingVault v, IERC20Mint a) = _setUpVault();
        vault = v;
        handler = new ProfitLockingHandler(v, a);
        targetContract(address(handler));
    }

    /// Outstanding shares must never convert to more assets than the vault holds.
    function invariant_solvency() public view {
        assertLe(
            vault.convertToAssets(vault.totalSupply()),
            vault.totalAssets() + 1,
            "INSOLVENT: convertToAssets(totalSupply) > totalAssets"
        );
    }

    /// Locked (unvested) profit shares can never exceed the vault's own share
    /// balance — it cannot lock shares it does not hold.
    function invariant_lockedNotExceedSelfBalance() public view {
        assertLe(
            vault.lockedShares(),
            vault.balanceOf(address(vault)),
            "PHANTOM LOCK: lockedShares > vault's own share balance"
        );
    }

    /// The vault's own share balance is exactly its still-locked plus
    /// already-unlocked (pending-burn) profit shares — no share is unaccounted.
    function invariant_selfBalanceAccounting() public view {
        assertEq(
            vault.lockedShares() + vault.unlockedShares(),
            vault.balanceOf(address(vault)),
            "ACCOUNTING: lockedShares + unlockedShares != vault's own share balance"
        );
    }
}
