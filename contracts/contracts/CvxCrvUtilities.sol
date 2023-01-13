// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./interfaces/ICvxMining.sol";
import "./interfaces/IStakingWrapper.sol";
import "./interfaces/IRewardHookExtended.sol";
import "./interfaces/IExtraRewardPool.sol";
import "./interfaces/IRewardStaking.sol";
import "./interfaces/ICvxCrvStaking.sol";


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
    uint256 private constant WEIGHT_PRECISION = 10000;

    address public immutable stkcvxcrv;

    constructor(address _stkcvxcrv) public{
        stkcvxcrv = _stkcvxcrv;
    }


    function apr(uint256 _rate, uint256 _priceOfReward, uint256 _priceOfDeposit) external view returns(uint256 _apr){
        return _rate * 365 days * _priceOfReward / _priceOfDeposit; 
    }


    //get reward rates for each token based on weighted reward group supply and wrapper's boosted cvxcrv rates
    //%return = rate * timeFrame * price of reward / price of LP / 1e18
    function mainRewardRates() public view returns (address[] memory tokens, uint256[] memory rates, uint256[] memory groups) {

        //get staked supply
        uint256 stakedSupply = IRewardStaking(cvxCrvStaking).totalSupply();

        //get wrapper supply
        uint256 wrapperSupply = IStakingWrapper(stkcvxcrv).totalSupply();

        //get wrapper staked balance
        uint256 wrappedStakedBalance = IRewardStaking(cvxCrvStaking).balanceOf(stkcvxcrv);

        // multiply reward rates by wrapper supply and wrapped staked balance
        uint256 wrappedRatio = 1e18;
        if(wrappedStakedBalance > 0){
            if(wrapperSupply > 0){
                wrappedRatio = wrappedStakedBalance * 1e18 / wrapperSupply;
            }else{
                wrappedRatio = 1000e18; //inf rate, just max out at 1000x
            }
        }

        //get reward count
        uint256 extraCount = IRewardStaking(cvxCrvStaking).extraRewardsLength();

        //add 2 for crv + minted cvx
        tokens = new address[](extraCount + 2);
        rates = new uint256[](extraCount + 2);
        groups = new uint256[](extraCount + 2);


        //first get rates from base (crv)
        {
            uint256 rate = IRewardStaking(cvxCrvStaking).rewardRate();
            (,uint8 group,,) = ICvxCrvStaking(stkcvxcrv).rewards(0); //always first slot

            uint256 groupSupply = ICvxCrvStaking(stkcvxcrv).rewardSupply(group);

            //rate per 1 staked cvxcrv
            if(stakedSupply > 0){
                rate = rate * 1e18 / stakedSupply;
            }

            //rate per 1 wrapped staked cvxcrv
            rate = rate * wrappedRatio / 1e18;

            //rate per 1 weighted supply of given reward group
            if(groupSupply > 0){
                rate = rate * wrapperSupply / groupSupply;
            }else{
                rate = rate * 1000; //no supply? apr inf so display 1000x
            }

            tokens[0] = crv;
            rates[0] = rate;
            groups[0] = group;

            //put minted cvx in last slot (there could be two cvx slots, one for direct rewards and one for mints)
            tokens[1] = cvx;
            rates[1] = ICvxMining(cvxMining).ConvertCrvToCvx(rate);
            (, uint8 cvxgroup,,) = ICvxCrvStaking(stkcvxcrv).rewards(1); //always second slot
            groups[1] = cvxgroup;
        }

        //loop through all vanilla staked cvxcrv reward contracts
        for (uint256 i = 0; i < extraCount; i++) {
            address extraPool = IRewardStaking(cvxCrvStaking).extraRewards(i);
            address extraToken = IRewardStaking(extraPool).rewardToken();
            uint256 rate = IRewardStaking(extraPool).rewardRate();

            uint256 rindex = ICvxCrvStaking(stkcvxcrv).registeredRewards(extraToken);
            (,uint8 group,,) = ICvxCrvStaking(stkcvxcrv).rewards(rindex-1);

            uint256 groupSupply = ICvxCrvStaking(stkcvxcrv).rewardSupply(group);

            //rate per 1 staked cvxcrv
            if(stakedSupply > 0){
                rate = rate * 1e18 / stakedSupply;
            }

            //rate per 1 wrapped staked cvxcrv
            rate = rate * wrappedRatio / 1e18;

            //rate per 1 weighted supply of given reward group
            if(groupSupply > 0){
                rate = rate * wrapperSupply / groupSupply;
            }else{
                rate = rate * 1000; //no supply? apr inf so display 1000x
            }

            tokens[i+2] = extraToken;
            rates[i+2] = rate;
            groups[i+2] = group;
        }
    }

    //get reward rates for a specific account taking into account their personal weighting
    function accountRewardRates(address _account) public view returns (address[] memory tokens, uint256[] memory rates, uint256[] memory groups) {
        (address[] memory t, uint256[] memory r, uint256[] memory g) = mainRewardRates();

        tokens = new address[](t.length);
        rates = new uint256[](t.length);
        groups = new uint256[](t.length);
        uint256 userWeight = ICvxCrvStaking(stkcvxcrv).userRewardWeight(_account);
        uint256 userbalance = ICvxCrvStaking(stkcvxcrv).balanceOf(_account);

        for(uint256 i = 0; i < tokens.length; i++){
            // uint256 rindex = ICvxCrvStaking(stkcvxcrv).registeredRewards(t[i]);
            // (,uint8 group,,) = ICvxCrvStaking(stkcvxcrv).rewards(rindex-1);
            tokens[i] = t[i];
            groups[i] = g[i];
            if(userbalance == 0){
                rates[i] = 0;
                continue;
            }

            if(g[i] == 0){
                rates[i] = r[i] * (WEIGHT_PRECISION - userWeight) / WEIGHT_PRECISION;
            }else{
                rates[i] = r[i] * userWeight / WEIGHT_PRECISION;
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
