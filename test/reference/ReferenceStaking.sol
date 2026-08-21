// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC20} from "./ReferenceVaults.sol";

/// @dev Synthetix-model StakingRewards (rewardPerToken accounting). Both
///      reference variants share this; they differ only in who may call
///      {notifyRewardAmount}.
abstract contract StakingBase {
    MockERC20 public immutable stakingToken;
    MockERC20 public immutable rewardsToken;
    address public immutable distributor;
    uint256 public constant duration = 7 days;

    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 internal _totalSupply;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    mapping(address => uint256) internal _balances;

    constructor(MockERC20 s, MockERC20 r) {
        stakingToken = s;
        rewardsToken = r;
        distributor = msg.sender;
    }

    function balanceOf(address a) external view returns (uint256) {
        return _balances[a];
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) return rewardPerTokenStored;
        return rewardPerTokenStored + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * 1e18) / _totalSupply;
    }

    function earned(address a) public view returns (uint256) {
        return (_balances[a] * (rewardPerToken() - userRewardPerTokenPaid[a])) / 1e18 + rewards[a];
    }

    modifier update(address a) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (a != address(0)) {
            rewards[a] = earned(a);
            userRewardPerTokenPaid[a] = rewardPerTokenStored;
        }
        _;
    }

    function stake(uint256 amt) external update(msg.sender) {
        _totalSupply += amt;
        _balances[msg.sender] += amt;
        stakingToken.transferFrom(msg.sender, address(this), amt);
    }

    function withdraw(uint256 amt) public update(msg.sender) {
        _totalSupply -= amt;
        _balances[msg.sender] -= amt;
        stakingToken.transfer(msg.sender, amt);
    }

    function getReward() public update(msg.sender) {
        uint256 r = rewards[msg.sender];
        if (r > 0) {
            rewards[msg.sender] = 0;
            rewardsToken.transfer(msg.sender, r);
        }
    }

    function _notify(uint256 reward) internal update(address(0)) {
        if (block.timestamp >= periodFinish) {
            rewardRate = reward / duration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (reward + leftover) / duration;
        }
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + duration;
    }

    function notifyRewardAmount(uint256 reward) external virtual;
}

/// @title StakingVulnerable — `notifyRewardAmount` callable by ANYONE.
/// @notice A griefer repeatedly notifies tiny amounts to re-stretch the period
///         and drop the reward rate, delaying/diluting stakers (real Sherlock
///         finding class). Nothing reverts.
contract StakingVulnerable is StakingBase {
    constructor(MockERC20 s, MockERC20 r) StakingBase(s, r) {}

    function notifyRewardAmount(uint256 reward) external override {
        _notify(reward);
    }
}

/// @title StakingSafe — `notifyRewardAmount` restricted to the distributor.
contract StakingSafe is StakingBase {
    constructor(MockERC20 s, MockERC20 r) StakingBase(s, r) {}

    function notifyRewardAmount(uint256 reward) external override {
        require(msg.sender == distributor, "not distributor");
        _notify(reward);
    }
}
