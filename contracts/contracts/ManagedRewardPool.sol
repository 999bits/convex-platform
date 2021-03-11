// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;
/**
 *Submitted for verification at Etherscan.io on 2020-07-17
 */

/*
   ____            __   __        __   _
  / __/__ __ ___  / /_ / /  ___  / /_ (_)__ __
 _\ \ / // // _ \/ __// _ \/ -_)/ __// / \ \ /
/___/ \_, //_//_/\__//_//_/\__/ \__//_/ /_\_\
     /___/

* Synthetix: ManagedRewardPool.sol
*
* Docs: https://docs.synthetix.io/
*
*
* MIT License
* ===========
*
* Copyright (c) 2020 Synthetix
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in all
* copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
*/

import "./Interfaces.sol";
import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/utils/Address.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';


contract BalanceWrapper {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function stake(address _account, uint256 amount) public virtual {
        _totalSupply = _totalSupply.add(amount);
        _balances[_account] = _balances[_account].add(amount);
    }

    function withdraw(address _account, uint256 amount) public virtual {
        _totalSupply = _totalSupply.sub(amount);
        _balances[_account] = _balances[_account].sub(amount);
    }
}

//synthetix reward contract with managed virtual balances
contract ManagedRewardPool is BalanceWrapper {
    using SafeERC20 for IERC20;

    IERC20 public rewardToken;
    uint256 public constant duration = 7 days;

    address public operator;
    address public governance;
    address public rewardManager;

    uint256 public pid;
    uint256 public starttime;
    uint256 public periodFinish = 0;
    uint256 public rewardRate = 0;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public queuedRewards = 0;
    uint256 public currentRewards = 0;
    uint256 public newRewardRatio = 750;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    address[] public extraRewards;

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);

    constructor(
        uint256 pid_,
        address rewardToken_,
        uint256 starttime_,
        address operator_,
        address rewardManager_
    ) public {
        pid = pid_;
        rewardToken = IERC20(rewardToken_);
        starttime = starttime_;
        operator = operator_;
        rewardManager = rewardManager_;
    }

    function extraRewardsLength() external view returns (uint256) {
        return extraRewards.length;
    }

    function addExtraReward(address _reward) external {
        require(msg.sender == rewardManager, "!authorized");
        require(_reward != address(0),"!reward setting");

        extraRewards.push(_reward);
    }

    function clearExtraRewards() external{
        require(msg.sender == rewardManager, "!authorized");
        delete extraRewards;
    }

    modifier checkStart() {
        require(block.timestamp >= starttime, 'RewardPool : not start');
        _;
    }

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return MathUtil.min(block.timestamp, periodFinish);
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalSupply() == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored.add(
                lastTimeRewardApplicable()
                    .sub(lastUpdateTime)
                    .mul(rewardRate)
                    .mul(1e18)
                    .div(totalSupply())
            );
    }

    function earned(address account) public view returns (uint256) {
        return
            balanceOf(account)
                .mul(rewardPerToken().sub(userRewardPerTokenPaid[account]))
                .div(1e18)
                .add(rewards[account]);
    }

    //only allow operator to stake as balances are virtual
    function stake(address _account, uint256 amount)
        public
        override
        updateReward(_account)
        checkStart
    {
        require(msg.sender == operator, "!authorized");
        require(amount > 0, 'RewardPool : Cannot stake 0');
        super.stake(_account, amount);
        emit Staked(_account, amount);

        //also stake to linked rewards
        for(uint i=0; i < extraRewards.length; i++){
            IRewards(extraRewards[i]).stake(_account, amount);
        }
    }

    //only allow operator to withdraw as balances are virtual
    //should call getReward before withdrawing from here though
    function withdraw(address _account, uint256 amount)
        public
        override
        updateReward(_account)
        checkStart
    {
        require(msg.sender == operator, "!authorized");
        require(amount > 0, 'RewardPool : Cannot withdraw 0');
        super.withdraw(_account, amount);
        emit Withdrawn(_account, amount);

        //also withdraw from linked rewards
        for(uint i=0; i < extraRewards.length; i++){
            IRewards(extraRewards[i]).withdraw(_account, amount);
        }
    }

    function exit(address _account) public {
        require(msg.sender == operator, "!authorized");
        withdraw(_account, balanceOf(_account));
    }

    function getReward(address _account, bool _claimExtras) public updateReward(_account) checkStart{
        uint256 reward = earned(_account);
        if (reward > 0) {
            rewards[_account] = 0;
            rewardToken.safeTransfer(_account, reward);
            IDeposit(operator).rewardClaimed(pid, _account, reward);
            emit RewardPaid(_account, reward);
        }

        //also get rewards from linked rewards
        if(_claimExtras){
            for(uint i=0; i < extraRewards.length; i++){
                IRewards(extraRewards[i]).getReward(_account);
            }
        }
    }

    function getReward(address _account) external{
        getReward(_account,true);
    }
    
    function getReward(bool _claimExtras) external{
        getReward(msg.sender,_claimExtras);
    }

    function getReward() external{
        getReward(msg.sender,true);
    }


    function queueNewRewards(uint256 _rewards) external {
        require(msg.sender == operator, "!authorized");

        _rewards = _rewards.add(queuedRewards);

        if (block.timestamp >= periodFinish) {
            notifyRewardAmount(_rewards);
            queuedRewards = 0;
            return;
        }

        uint256 queuedRatio = currentRewards.mul(1000).div(_rewards);
        if(queuedRatio < newRewardRatio){
            notifyRewardAmount(_rewards);
            queuedRewards = 0;
        }else{
            queuedRewards = _rewards;
        }
    }

    function notifyRewardAmount(uint256 reward)
        internal
        updateReward(address(0))
    {
       // require(msg.sender == operator, "!authorized");
        if (block.timestamp > starttime) {
            if (block.timestamp >= periodFinish) {
                rewardRate = reward.div(duration);
            } else {
                uint256 remaining = periodFinish.sub(block.timestamp);
                uint256 leftover = remaining.mul(rewardRate);
                reward = reward.add(leftover);
                rewardRate = reward.div(duration);
            }
            currentRewards = reward;
            lastUpdateTime = block.timestamp;
            periodFinish = block.timestamp.add(duration);
            emit RewardAdded(reward);
        } else {
            rewardRate = reward.div(duration);
            lastUpdateTime = starttime;
            periodFinish = starttime.add(duration);
            currentRewards = reward;
            emit RewardAdded(reward);
        }
    }
}