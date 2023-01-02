// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./interfaces/ICvxMining.sol";
import "./interfaces/IStakingWrapper.sol";
import "./interfaces/IRewardHookExtended.sol";
import "./interfaces/IExtraRewardPool.sol";
import "./interfaces/IRewardStaking.sol";


/*
This is a utility library which is mainly used for off chain calculations
*/
contract CvxCrvUtilities{

    uint256 private constant WEEK = 7 * 86400;

    address public constant convexProxy = address(0x989AEb4d175e16225E39E87d0D97A3360524AD80);
    address public constant cvxCrvStaking = address(0x3Fe65692bfCD0e6CF84cB1E7d24108E434A7587e);
    address public constant crv = address(0xD533a949740bb3306d119CC777fa900bA034cd52);
    address public constant cvx = address(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);
    address public constant cvxMining = address(0x3c75BFe6FbfDa3A94E7E7E8c2216AFc684dE5343);


    address public immutable stkcvxcrv;

    constructor(address _stkcvxcrv) public{
        stkcvxcrv = _stkcvxcrv;
    }


    //get boosted reward rate of user at a specific staking contract
    //returns amount user receives per second based on weight/liq ratio
    //%return = userBoostedRewardRate * timeFrame * price of reward / price of LP / 1e18
    function mainRewardRates() public view returns (address[] memory tokens, uint256[] memory rates) {

        //get staked supply
        uint256 stakedSupply = IRewardStaking(cvxCrvStaking).totalSupply();

        //get wrapper supply
        uint256 wrapperSupply = IStakingWrapper(stkcvxcrv).totalSupply();

        //get wrapper staked balance
        uint256 wrappedStakedBalance = IRewardStaking(cvxCrvStaking).balanceOf(stkcvxcrv);

        // multiply reward rates by wrapper supply and wrapped staked balance
        uint256 wrappedRatio = wrapperSupply * 1e18 / wrappedStakedBalance;

        //get reward count
        uint256 extraCount = IRewardStaking(cvxCrvStaking).extraRewardsLength();

        //add 1 for cvx
        tokens = new address[](extraCount + 1);
        rates = new uint256[](extraCount + 1);

        //loop through all vanilla staked cvxcrv reward contracts
        for (uint256 i = 0; i < extraCount; i++) {
            address extraPool = IRewardStaking(cvxCrvStaking).extraRewards(i);
            address extraToken = IRewardStaking(extraPool).rewardToken();
            uint256 rate = IRewardStaking(extraPool).rewardRate();

            //rate per 1 staked cvxcrv
            rate = rate * 1e18 / stakedSupply;

            //boosted rate of wrapper
            rate = rate * wrappedRatio / 1e18;

            //add minted cvx for crv -> cvx = CvxMining.ConvertCrvToCvx(crv);
            if(extraToken == crv){
                //put cvx in last slot
                tokens[extraCount] = cvx;
                rates[extraCount] = ICvxMining(cvxMining).ConvertCrvToCvx(rate);
            }
        }
    }

     function externalRewardContracts() public view returns (address[] memory rewardContracts) {
        //get reward hook
        address hook = IStakingWrapper(stkcvxcrv).rewardHook();

        uint256 rewardCount = IRewardHookExtended(hook).poolRewardLength(stkcvxcrv);
        rewardContracts = new address[](rewardCount);

        for(uint256 i = 0; i < rewardCount; i++){
            rewardContracts[i] = IRewardHookExtended(hook).poolRewardList(stkcvxcrv, i);
        }
    }

    function aggregateExtraRewardRates() external view returns(address[] memory tokens, uint256[] memory rates){
        address[] memory rewardContracts = externalRewardContracts();

        tokens = new address[](rewardContracts.length);
        rates = new uint256[](rewardContracts.length);

        for(uint256 i = 0; i < rewardContracts.length; i++){
            IExtraRewardPool.PoolType pt = IExtraRewardPool(rewardContracts[i]).poolType();
            if(pt == IExtraRewardPool.PoolType.Single){
                (address t, uint256 r) = singleRewardRate(rewardContracts[i]);
                tokens[i] = t;
                rates[i] = r;
            }
        }
    }

    function singleRewardRate(address _rewardContract) public view returns (address token, uint256 rate) {
        
        //set token
        token = IExtraRewardPool(_rewardContract).rewardToken();

        //check period finish
        if(IExtraRewardPool(_rewardContract).periodFinish() < block.timestamp ){
            //return early as rate is 0
            return (token,0);
        }

        //get global rate and supply
        uint256 globalRate = IExtraRewardPool(_rewardContract).rewardRate();
        uint256 totalSupply = IExtraRewardPool(_rewardContract).totalSupply();
        

        if(totalSupply > 0){
            //get rate for whole pool (vs other pools)
            rate = globalRate * IExtraRewardPool(_rewardContract).balanceOf(stkcvxcrv) / totalSupply;

            //get pool total supply
            uint256 poolSupply = IStakingWrapper(stkcvxcrv).totalSupply();
            if(poolSupply > 0){
                //rate per deposit
                rate = rate * 1e18 / poolSupply;
            }
        }
    }
}
