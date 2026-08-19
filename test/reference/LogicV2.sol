// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title LogicV2Bad (VULNERABLE — storage collision)
/// @notice A V2 upgrade that adds a `version` field at the FRONT of the layout.
/// The proxy keeps its old storage across an upgrade, so every variable now
/// reads a different slot than it was written to:
///   slot 0: version       (was owner)
///   slot 1: owner          (was totalDeposited)
///   slot 2: totalDeposited (was empty)
/// After the upgrade `owner` reads the old deposit total and the vault's real
/// owner is gone.
contract LogicV2Bad {
    uint256 public version;
    address public owner;
    uint256 public totalDeposited;

    function deposit() external payable {
        totalDeposited += msg.value;
    }

    function ownerWithdraw() external {
        require(msg.sender == owner, "not owner");
        (bool ok,) = msg.sender.call{value: address(this).balance}("");
        require(ok, "send failed");
    }
}

/// @title LogicV2Good
/// @notice The same feature added the safe way — appended after the existing
/// layout, so the old slots keep their meaning:
///   slot 0: owner
///   slot 1: totalDeposited
///   slot 2: version   (new, appended)
contract LogicV2Good {
    address public owner;
    uint256 public totalDeposited;
    uint256 public version;

    function deposit() external payable {
        totalDeposited += msg.value;
    }

    function ownerWithdraw() external {
        require(msg.sender == owner, "not owner");
        (bool ok,) = msg.sender.call{value: address(this).balance}("");
        require(ok, "send failed");
    }
}
