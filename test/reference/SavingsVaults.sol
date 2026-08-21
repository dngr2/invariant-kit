// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC20} from "./ReferenceVaults.sol";

/// @title SavingsVaultBase — a tiny interest-bearing savings vault
/// @notice Users deposit an asset and are owed their principal plus whatever
///         interest the vault credits them via {accrue}. `totalOwed` is the sum of
///         everyone's balance; `assetBalance` is what the vault actually holds
///         (deposits + a pre-funded reserve buffer it can pay interest out of).
///
///         The only behaviour that differs between the correct and the broken
///         reference is {_accrue}; everything else is shared so the bug is isolated
///         to one override.
abstract contract SavingsVaultBase {
    MockERC20 public immutable token;

    mapping(address => uint256) public owedTo;
    uint256 public totalOwed;

    constructor(MockERC20 t) {
        token = t;
    }

    /// Assets the vault holds right now (adapter view).
    function assetBalance() public view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function deposit(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        owedTo[msg.sender] += amount;
        totalOwed += amount;
    }

    function withdraw(uint256 amount) external {
        require(amount <= owedTo[msg.sender], "insufficient balance");
        owedTo[msg.sender] -= amount;
        totalOwed -= amount;
        token.transfer(msg.sender, amount);
    }

    /// Credit interest to a saver. The two references differ only here.
    function accrue(address user, uint256 interest) external {
        _accrue(user, interest);
    }

    function _accrue(address user, uint256 interest) internal virtual;
}

/// @title ReserveCappedSavingsVault (CORRECT)
/// @notice Only promises the interest its reserves can actually cover: it credits
///         at most the surplus (`assetBalance - totalOwed`) it holds over what it
///         already owes, so liabilities can never outgrow assets.
contract ReserveCappedSavingsVault is SavingsVaultBase {
    constructor(MockERC20 t) SavingsVaultBase(t) {}

    function _accrue(address user, uint256 interest) internal override {
        uint256 bal = assetBalance();
        uint256 surplus = bal > totalOwed ? bal - totalOwed : 0;
        if (interest > surplus) interest = surplus; // pay only what reserves back
        owedTo[user] += interest;
        totalOwed += interest;
    }
}

/// @title OverpromisingSavingsVault (VULNERABLE — pays interest it does not hold)
/// @notice Credits the full interest regardless of reserves, so `totalOwed` grows
///         past `assetBalance` and the vault is silently insolvent — savers
///         collectively believe they can withdraw more than the vault holds, and
///         the last ones out get nothing. Nothing reverts.
///
///         `ReserveSolvencyInvariant.invariant_reserveCoversLiabilities` catches
///         it: after unbacked interest is credited, `assetBalance < totalOwed`.
contract OverpromisingSavingsVault is SavingsVaultBase {
    constructor(MockERC20 t) SavingsVaultBase(t) {}

    function _accrue(address user, uint256 interest) internal override {
        // BUG: no reserve check — promises interest the vault has no assets for.
        owedTo[user] += interest;
        totalOwed += interest;
    }
}
