// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "../interfaces/IRewardStaking.sol";
import "../interfaces/IConvexDeposits.sol";
import "../interfaces/CvxMining.sol";
import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/utils/Address.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
// import "@openzeppelin/contracts/access/Ownable.sol";


//Example of a tokenize a convex staked position.
//if used as collateral some modifications will be needed to fit the specific platform

//Based on Curve.fi's gauge wrapper implementations at https://github.com/curvefi/curve-dao-contracts/tree/master/contracts/gauges/wrappers
contract ConvexStakingWrapper is ERC20, ReentrancyGuard {
    using SafeERC20
    for IERC20;
    using Address
    for address;
    using SafeMath
    for uint256;

    struct EarnedData {
        address token;
        uint256 amount;
    }

    struct RewardType {
        address reward_token;
        address reward_pool;
        uint128 reward_integral;
        uint128 reward_remaining;
        mapping(address => uint256) reward_integral_for;
        mapping(address => uint256) claimable_reward;
    }

    //constants/immutables
    address public constant convexBooster = address(0xF403C135812408BFbE8713b5A23a04b3D48AAE31);
    address public constant crv = address(0xD533a949740bb3306d119CC777fa900bA034cd52);
    address public constant cvx = address(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);
    address public curveToken;
    address public convexToken;
    address public convexPool;
    uint256 public convexPoolId;
    address public collateralVault;
    uint256 private constant CRV_INDEX = 0;
    uint256 private constant CVX_INDEX = 1;

    //rewards
    RewardType[] public rewards;
    mapping(address => uint256) public registeredRewards;

    //management
    bool public isShutdown;
    bool public isInit;
    address public owner;

    string internal _tokenname;
    string internal _tokensymbol;

    event Deposited(address indexed _user, address indexed _account, uint256 _amount, bool _wrapped);
    event Withdrawn(address indexed _user, uint256 _amount, bool _unwrapped);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor() public
        ERC20(
            "StakedConvexToken",
            "stkCvx"
        ){
    }

    function initialize(address _curveToken, address _convexToken, address _convexPool, uint256 _poolId, address _vault)
    virtual external {
        require(!isInit,"already init");
        owner = msg.sender;
        emit OwnershipTransferred(address(0), owner);

        _tokenname = string(abi.encodePacked("Staked ", ERC20(_convexToken).name() ));
        _tokensymbol = string(abi.encodePacked("stk", ERC20(_convexToken).symbol()));
        isShutdown = false;
        isInit = true;
        curveToken = _curveToken;
        convexToken = _convexToken;
        convexPool = _convexPool;
        convexPoolId = _poolId;
        collateralVault = _vault;

        //add rewards
        addRewards();
        setApprovals();
    }

    function name() public view override returns (string memory) {
        return _tokenname;
    }

    function symbol() public view override returns (string memory) {
        return _tokensymbol;
    }

    function decimals() public view override returns (uint8) {
        return 18;
    }

    modifier onlyOwner() {
        require(owner == msg.sender, "Ownable: caller is not the owner");
        _;
    }

    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function renounceOwnership() public virtual onlyOwner {
        emit OwnershipTransferred(owner, address(0));
        owner = address(0);
    }

    function shutdown() external onlyOwner {
        isShutdown = true;
    }

    function setApprovals() public {
        IERC20(curveToken).safeApprove(convexBooster, 0);
        IERC20(curveToken).safeApprove(convexBooster, uint256(-1));
        IERC20(convexToken).safeApprove(convexPool, 0);
        IERC20(convexToken).safeApprove(convexPool, uint256(-1));
    }

    function addRewards() public {
        address mainPool = convexPool;

        if (rewards.length == 0) {
            rewards.push(
                RewardType({
                    reward_token: crv,
                    reward_pool: mainPool,
                    reward_integral: 0,
                    reward_remaining: 0
                })
            );
            rewards.push(
                RewardType({
                    reward_token: cvx,
                    reward_pool: address(0),
                    reward_integral: 0,
                    reward_remaining: 0
                })
            );
            registeredRewards[crv] = CRV_INDEX+1; //mark registered at index+1
            registeredRewards[cvx] = CVX_INDEX+1; //mark registered at index+1
        }

        uint256 extraCount = IRewardStaking(mainPool).extraRewardsLength();
        for (uint256 i = 0; i < extraCount; i++) {
            address extraPool = IRewardStaking(mainPool).extraRewards(i);
            address extraToken = IRewardStaking(extraPool).rewardToken();
            if(extraToken == cvx){
                //update cvx reward pool address
                rewards[CVX_INDEX].reward_pool = extraPool;
            }else if(registeredRewards[extraToken] == 0){
                //add new token to list
                rewards.push(
                    RewardType({
                        reward_token: IRewardStaking(extraPool).rewardToken(),
                        reward_pool: extraPool,
                        reward_integral: 0,
                        reward_remaining: 0
                    })
                );
                registeredRewards[extraToken] = rewards.length; //mark registered at index+1
            }
        }
    }

    function rewardLength() external view returns(uint256) {
        return rewards.length;
    }

    function _getDepositedBalance(address _account) internal virtual view returns(uint256) {
        if (_account == address(0) || _account == collateralVault) {
            return 0;
        }
        //get balance from collateralVault

        return balanceOf(_account);
    }

    function _getTotalSupply() internal virtual view returns(uint256){

        //override and add any supply needed (interest based growth)

        return totalSupply();
    }

    function _calcRewardIntegral(uint256 _index, address[2] memory _accounts, uint256[2] memory _balances, uint256 _supply, bool _isClaim) internal{
         RewardType storage reward = rewards[_index];

        //get difference in balance and remaining rewards
        //getReward is unguarded so we use reward_remaining to keep track of how much was actually claimed
        uint256 bal = IERC20(reward.reward_token).balanceOf(address(this));
        // uint256 d_reward = bal.sub(reward.reward_remaining);

        if (_supply > 0 && bal.sub(reward.reward_remaining) > 0) {
            reward.reward_integral = reward.reward_integral + uint128(bal.sub(reward.reward_remaining).mul(1e20).div(_supply));
        }

        //update user integrals
        for (uint256 u = 0; u < _accounts.length; u++) {
            //do not give rewards to address 0
            if (_accounts[u] == address(0)) continue;
            if (_accounts[u] == collateralVault) continue;

            uint userI = reward.reward_integral_for[_accounts[u]];
            if(_isClaim || userI < reward.reward_integral){
                if(_isClaim){
                    uint256 receiveable = reward.claimable_reward[_accounts[u]].add(_balances[u].mul( uint256(reward.reward_integral).sub(userI)).div(1e20));
                    if(receiveable > 0){
                        reward.claimable_reward[_accounts[u]] = 0;
                        IERC20(reward.reward_token).safeTransfer(_accounts[u], receiveable);
                        bal = bal.sub(receiveable);
                    }
                }else{
                    reward.claimable_reward[_accounts[u]] = reward.claimable_reward[_accounts[u]].add(_balances[u].mul( uint256(reward.reward_integral).sub(userI)).div(1e20));
                }
                reward.reward_integral_for[_accounts[u]] = reward.reward_integral;
            }
        }

        //update remaining reward here since balance could have changed if claiming
        if(bal != reward.reward_remaining){
            reward.reward_remaining = uint128(bal);
        }
    }

    function _checkpoint(address[2] memory _accounts) internal {
        //if shutdown, no longer checkpoint in case there are problems
        if(isShutdown) return;

        uint256 supply = _getTotalSupply();
        uint256[2] memory depositedBalance;
        depositedBalance[0] = _getDepositedBalance(_accounts[0]);
        depositedBalance[1] = _getDepositedBalance(_accounts[1]);
        
        IRewardStaking(convexPool).getReward(address(this), true);

        uint256 rewardCount = rewards.length;
        for (uint256 i = 0; i < rewardCount; i++) {
           _calcRewardIntegral(i,_accounts,depositedBalance,supply,false);
        }
    }

    function _checkpointAndClaim(address[2] memory _accounts) internal {

        uint256 supply = _getTotalSupply();
        uint256[2] memory depositedBalance;
        depositedBalance[0] = _getDepositedBalance(_accounts[0]); //only do first slot
        
        IRewardStaking(convexPool).getReward(address(this), true);

        uint256 rewardCount = rewards.length;
        for (uint256 i = 0; i < rewardCount; i++) {
           _calcRewardIntegral(i,_accounts,depositedBalance,supply,true);
        }
    }

    function user_checkpoint(address[2] calldata _accounts) external returns(bool) {
        _checkpoint([_accounts[0], _accounts[1]]);
        return true;
    }

    function totalBalanceOf(address _account) external view returns(uint256){
        return _getDepositedBalance(_account);
    }

    function earned(address _account) external view returns(EarnedData[] memory claimable) {
        uint256 supply = _getTotalSupply();
        // uint256 depositedBalance = _getDepositedBalance(_account);
        uint256 rewardCount = rewards.length;
        claimable = new EarnedData[](rewardCount);

        for (uint256 i = 0; i < rewardCount; i++) {
            RewardType storage reward = rewards[i];

            if(reward.reward_pool == address(0)){
                //cvx reward may not have a reward pool yet
                //so just add whats already been checkpointed
                claimable[i].amount = claimable[i].amount.add(reward.claimable_reward[_account]);
                claimable[i].token = reward.reward_token;
                continue;
            }

            //change in reward is current balance - remaining reward + earned
            uint256 bal = IERC20(reward.reward_token).balanceOf(address(this));
            uint256 d_reward = bal.sub(reward.reward_remaining);
            d_reward = d_reward.add(IRewardStaking(reward.reward_pool).earned(address(this)));

            uint256 I = reward.reward_integral;
            if (supply > 0) {
                I = I + d_reward.mul(1e20).div(supply);
            }

            uint256 newlyClaimable = _getDepositedBalance(_account).mul(I.sub(reward.reward_integral_for[_account])).div(1e20);
            claimable[i].amount = claimable[i].amount.add(reward.claimable_reward[_account].add(newlyClaimable));
            claimable[i].token = reward.reward_token;

            //calc cvx minted from crv and add to cvx claimables
            //note: crv is always index 0 so will always run before cvx
            if(i == CRV_INDEX){
                //because someone can call claim for the pool outside of checkpoints, need to recalculate crv without the local balance
                I = reward.reward_integral;
                if (supply > 0) {
                    I = I + IRewardStaking(reward.reward_pool).earned(address(this)).mul(1e20).div(supply);
                }
                newlyClaimable = _getDepositedBalance(_account).mul(I.sub(reward.reward_integral_for[_account])).div(1e20);
                claimable[CVX_INDEX].amount = CvxMining.ConvertCrvToCvx(newlyClaimable);
                claimable[CVX_INDEX].token = cvx;
            }
        }
        return claimable;
    }

    function getReward(address _account) external {
        //claim directly in checkpoint logic to save a bit of gas
        _checkpointAndClaim([_account, address(0)]);
    }

    //deposit a curve token
    function deposit(uint256 _amount, address _to) external nonReentrant {
        require(!isShutdown, "shutdown");

        //dont need to call checkpoint since _mint() will

        if (_amount > 0) {
            _mint(_to, _amount);
            IERC20(curveToken).safeTransferFrom(msg.sender, address(this), _amount);
            IConvexDeposits(convexBooster).deposit(convexPoolId, _amount, true);
        }

        emit Deposited(msg.sender, _to, _amount, true);
    }

    //stake a convex token
    function stake(uint256 _amount, address _to) external nonReentrant {
        require(!isShutdown, "shutdown");

        //dont need to call checkpoint since _mint() will

        if (_amount > 0) {
            _mint(_to, _amount);
            IERC20(convexToken).safeTransferFrom(msg.sender, address(this), _amount);
            IRewardStaking(convexPool).stake(_amount);
        }

        emit Deposited(msg.sender, _to, _amount, false);
    }

    //withdraw to convex deposit token
    function withdraw(uint256 _amount) external nonReentrant {

        //dont need to call checkpoint since _burn() will

        if (_amount > 0) {
            _burn(msg.sender, _amount);
            IRewardStaking(convexPool).withdraw(_amount, false);
            IERC20(convexToken).safeTransfer(msg.sender, _amount);
        }

        emit Withdrawn(msg.sender, _amount, false);
    }

    //withdraw to underlying curve lp token
    function withdrawAndUnwrap(uint256 _amount) external nonReentrant {
        
        //dont need to call checkpoint since _burn() will

        if (_amount > 0) {
            _burn(msg.sender, _amount);
            IRewardStaking(convexPool).withdrawAndUnwrap(_amount, false);
            IERC20(curveToken).safeTransfer(msg.sender, _amount);
        }

        //events
        emit Withdrawn(msg.sender, _amount, true);
    }

    function _beforeTokenTransfer(address _from, address _to, uint256 _amount) internal override {
        _checkpoint([_from, _to]);
    }
}