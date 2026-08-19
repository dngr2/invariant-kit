// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title LogicV1 (VULNERABLE — unprotected initializer)
/// @notice Vault logic run behind the proxy. `initialize` sets the owner but has
/// no one-time guard, so anyone can call it again through the proxy, overwrite
/// `owner`, and then drain the vault with `ownerWithdraw`.
///
/// Storage layout (these are the proxy's slots under delegatecall):
///   slot 0: owner
///   slot 1: totalDeposited
contract LogicV1 {
    address public owner;
    uint256 public totalDeposited;

    function initialize(address _owner) external {
        owner = _owner; // BUG: no `initializer` guard — callable repeatedly
    }

    function deposit() external payable {
        totalDeposited += msg.value;
    }

    function ownerWithdraw() external {
        require(msg.sender == owner, "not owner");
        (bool ok,) = msg.sender.call{value: address(this).balance}("");
        require(ok, "send failed");
    }
}

/// @title LogicV1Fixed
/// @notice Same logic with a one-time `initializer` guard, so ownership can only
/// be set once. (A production version would also call `_disableInitializers()`
/// in the implementation's constructor so the implementation itself can't be
/// initialized.)
contract LogicV1Fixed {
    address public owner;
    uint256 public totalDeposited;
    bool private _initialized;

    modifier initializer() {
        require(!_initialized, "already initialized");
        _initialized = true;
        _;
    }

    function initialize(address _owner) external initializer {
        owner = _owner;
    }

    function deposit() external payable {
        totalDeposited += msg.value;
    }

    function ownerWithdraw() external {
        require(msg.sender == owner, "not owner");
        (bool ok,) = msg.sender.call{value: address(this).balance}("");
        require(ok, "send failed");
    }
}
