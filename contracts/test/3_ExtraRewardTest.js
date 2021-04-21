const { BN, constants, expectEvent, expectRevert, time } = require('openzeppelin-test-helpers');
var jsonfile = require('jsonfile');
var contractList = jsonfile.readFileSync('./contracts.json');

const Booster = artifacts.require("Booster");
const CrvDepositor = artifacts.require("CrvDepositor");
const CurveVoterProxy = artifacts.require("CurveVoterProxy");
const ExtraRewardStashV2 = artifacts.require("ExtraRewardStashV2");
const BaseRewardPool = artifacts.require("BaseRewardPool");
const VirtualBalanceRewardPool = artifacts.require("VirtualBalanceRewardPool");
const cvxRewardPool = artifacts.require("cvxRewardPool");
const ConvexToken = artifacts.require("ConvexToken");
const cCrvToken = artifacts.require("cCrvToken");
const StashFactory = artifacts.require("StashFactory");
const RewardFactory = artifacts.require("RewardFactory");
const PoolManager = artifacts.require("PoolManager");


const IExchange = artifacts.require("IExchange");
const I2CurveFi = artifacts.require("I2CurveFi");
const I3CurveFi = artifacts.require("I3CurveFi");
const IERC20 = artifacts.require("IERC20");
const ICurveGauge = artifacts.require("ICurveGauge");
const ICurveGaugeDebug = artifacts.require("ICurveGaugeDebug");


contract("ExtraRewardsTest v2", async accounts => {
  it("should deposit and claim crv/cvx as well as extra incentives", async () => {
    
    let crv = await IERC20.at("0xD533a949740bb3306d119CC777fa900bA034cd52");
    let threeCrv = await IERC20.at("0x6c3F90f043a72FA612cbac8115EE7e52BDe6E490");
    let weth = await IERC20.at("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2");
    let wbtc = await IERC20.at("0x2260fac5e5542a773aa44fbcfedf7c193bc2c599");
    let bor = await IERC20.at("0x89Ab32156e46F46D02ade3FEcbe5Fc4243B9AAeD");
    let exchange = await IExchange.at("0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D");
    let sbtcswap = await I3CurveFi.at("0x7fC77b5c7614E1533320Ea6DDc2Eb61fa00A9714");
    let sbtc = await IERC20.at("0x075b1bb99792c9E1041bA13afEf80C91a1e70fB3");
    let obtcswap = await I2CurveFi.at("0x7F55DDe206dbAD629C080068923b36fe9D6bDBeF");
    let obtc = await IERC20.at("0xDE5331AC4B3630f94853Ff322B66407e0D6331E8");
    let obtcGauge = await ICurveGauge.at("0xd7d147c6Bb90A718c3De8C0568F9B560C79fa416");
    let obtcGaugeDebug = await ICurveGaugeDebug.at("0xd7d147c6Bb90A718c3De8C0568F9B560C79fa416");
    let obtcSwap = "0x7F55DDe206dbAD629C080068923b36fe9D6bDBeF";


    let admin = accounts[0];
    let userA = accounts[1];
    let userB = accounts[2];
    let caller = accounts[3];

    //system setup
    let voteproxy = await CurveVoterProxy.deployed();
    let booster = await Booster.deployed();
    let rewardFactory = await RewardFactory.deployed();
    let stashFactory = await StashFactory.deployed();
    let poolManager = await PoolManager.deployed();
    let cvx = await ConvexToken.deployed();
    let cCrv = await cCrvToken.deployed();
    let crvDeposit = await CrvDepositor.deployed();
    let cCrvRewards = await booster.lockRewards();
    let cvxRewards = await booster.stakerRewards();
    let cCrvRewardsContract = await BaseRewardPool.at(cCrvRewards);
    let cvxRewardsContract = await cvxRewardPool.at(cvxRewards);

    //changed to pbtc since obtc rewards were not refilled while testing
    var poolId = contractList.pools.find(pool => pool.name == "pbtc").id;
    let poolinfo = await booster.poolInfo(poolId);
    let rewardPoolAddress = poolinfo.crvRewards;
    let rewardPool = await BaseRewardPool.at(rewardPoolAddress);
    console.log("pool lp token " +poolinfo.lptoken);
    console.log("pool gauge " +poolinfo.gauge);
    console.log("pool reward contract at " +rewardPool.address);
    let stash = poolinfo.stash;
    let rewardStash = await ExtraRewardStashV2.at(stash);
    //make sure we spawned a v2 stash
    await rewardStash.getName().then(a=>console.log("stash name: " +a));

    let starttime = await time.latest();
    console.log("current block time: " +starttime)
    await time.latestBlock().then(a=>console.log("current block: " +a));

    //exchange and deposit for obtc lp tokens
    await weth.sendTransaction({value:web3.utils.toWei("5.0", "ether"),from:userA});
    let startingWeth = await weth.balanceOf(userA);
    await weth.approve(exchange.address,startingWeth,{from:userA});
    await exchange.swapExactTokensForTokens(startingWeth,0,[weth.address,wbtc.address],userA,starttime+3000,{from:userA});
    let startingwbtc = await wbtc.balanceOf(userA);
    await wbtc.approve(sbtcswap.address,0,{from:userA});
    await wbtc.approve(sbtcswap.address,startingwbtc,{from:userA});
    await sbtcswap.add_liquidity([0,startingwbtc,0],0,{from:userA});
    let startingsbtc = await sbtc.balanceOf(userA);
    await sbtc.approve(obtcswap.address,0,{from:userA});
    await sbtc.approve(obtcswap.address,startingsbtc,{from:userA});
    await obtcswap.add_liquidity([0,startingsbtc],0,{from:userA});
    let startingobtc = await obtc.balanceOf(userA);
    console.log("obtc lp: " +startingobtc);
 
    //approve and partial deposit
    await obtc.approve(booster.address,0,{from:userA});
    await obtc.approve(booster.address,startingobtc,{from:userA});
    await booster.deposit(poolId,web3.utils.toWei("0.1", "ether"),true,{from:userA});
    console.log("partial deposit complete");

    //confirm deposit
    //should be no bor collected yet
    await obtc.balanceOf(userA).then(a=>console.log("userA obtc: " +a));
    await rewardPool.balanceOf(userA).then(a=>console.log("deposited lp: " +a));
    await obtcGauge.balanceOf(voteproxy.address).then(a=>console.log("gaugeBalance: " +a));
    await bor.balanceOf(rewardStash.address).then(a=>console.log("bor on stash (==0): " +a));
    await bor.balanceOf(voteproxy.address).then(a=>console.log("bor on voter (==0): " +a));
    await bor.balanceOf(booster.address).then(a=>console.log("bor on deposit (==0): " +a));


    //advance time
    await time.increase(86400);
    await time.advanceBlock();
    await time.advanceBlock();
    console.log("advance time...");
    await time.latest().then(a=>console.log("current block time: " +a));
    await time.latestBlock().then(a=>console.log("current block: " +a));

    //collect and distribute rewards off gauge
    await booster.earmarkRewards(poolId,{from:caller});
    console.log("earmark 1")

    //make sure stash added bor token and reward pool added bor rewards to its child list
    await rewardPool.extraRewardsLength().then(a=>console.log("reward pool extra rewards: " +a));
    await rewardStash.tokenCount().then(a=>console.log("stash token count: " +a));
    let tokenInfo = await rewardStash.tokenInfo(0);
    console.log("bor token rewards (from stash): " +tokenInfo.rewardAddress);
    let borRewardsAddress = await rewardPool.extraRewards(0);
    let borRewards = await VirtualBalanceRewardPool.at(borRewardsAddress);
    console.log("bor token rewards (from main rewards): " +borRewards.address);

    //make sure crv and bor is where it should be
    await crv.balanceOf(voteproxy.address).then(a=>console.log("crv at voteproxy " +a));
    await crv.balanceOf(booster.address).then(a=>console.log("crv at booster " +a));
    await crv.balanceOf(caller).then(a=>console.log("crv at caller " +a));
    await crv.balanceOf(rewardPool.address).then(a=>console.log("crv at reward pool " +a));
    await crv.balanceOf(cCrvRewards).then(a=>console.log("crv at cCrvRewards " +a));
    await crv.balanceOf(cvxRewards).then(a=>console.log("crv at cvxRewards " +a));
    await crv.balanceOf(userA).then(a=>console.log("userA crv: " +a))
    await rewardPool.earned(userA).then(a=>console.log("rewards earned(unclaimed): " +a));

    await bor.balanceOf(rewardStash.address).then(a=>console.log("bor on stash (==0): " +a));
    await bor.balanceOf(voteproxy.address).then(a=>console.log("bor on voter (==0): " +a));
    await bor.balanceOf(booster.address).then(a=>console.log("bor on deposit (==0): " +a));
    await bor.balanceOf(borRewards.address).then(a=>console.log("bor on rewards (>0): " +a));
    
    //increase time
    //if over a week with no claiming and rewards stoped,
    //rewards on staker could become unretriable. we assume proper claiming happens
    //multiple times within the week timeframe
    //await time.increase(10*86400); 
    await time.increase(6*86400);
    await time.advanceBlock();
    await time.advanceBlock();
    await time.advanceBlock();
    await time.advanceBlock();
    console.log("advance time...");
    await time.latest().then(a=>console.log("current block time: " +a));
    await time.latestBlock().then(a=>console.log("current block: " +a));

    //check gauge claimables
    await obtcGaugeDebug.claimable_tokens(voteproxy.address).then(a=>console.log("claimableTokens: " +a));
    await obtcGaugeDebug.claimable_reward(voteproxy.address, bor.address).then(a=>console.log("claimableRewards: " +a));

    //deposit remaining funds,  should trigger bor rewards to be claimed
    await booster.depositAll(poolId,true,{from:userA});
    console.log("Deposit All")

    //stash should catch rewards after a deposit
    await bor.balanceOf(rewardStash.address).then(a=>console.log("bor on stash (>0): " +a));
    await bor.balanceOf(voteproxy.address).then(a=>console.log("bor on voter2 (==0): " +a));
    await bor.balanceOf(booster.address).then(a=>console.log("bor on deposit0 (==0): " +a));
    await bor.balanceOf(borRewards.address).then(a=>console.log("bor on rewards (>0): " +a));

    //increase time
    await time.increase(10*86400);
    await time.advanceBlock();
    await time.advanceBlock();
    await time.advanceBlock();
    await time.advanceBlock();
    console.log("advance time...");
    await time.latest().then(a=>console.log("current block time: " +a));
    await time.latestBlock().then(a=>console.log("current block: " +a));

    //check gauge claimables
    await obtcGaugeDebug.claimable_tokens(voteproxy.address).then(a=>console.log("claimableTokens: " +a));
    await obtcGaugeDebug.claimable_reward(voteproxy.address, bor.address).then(a=>console.log("claimableRewards: " +a));
    
    //claim crv and bor rewards, move all from stash to reward contract
    await booster.earmarkRewards(poolId,{from:caller});
    console.log("earmark 2")

    //check balances, stashed bor should now be on rewards
    await crv.balanceOf(voteproxy.address).then(a=>console.log("crv at voteproxy " +a));
    await crv.balanceOf(booster.address).then(a=>console.log("crv at booster " +a));
    await crv.balanceOf(caller).then(a=>console.log("crv at caller " +a));
    await crv.balanceOf(rewardPool.address).then(a=>console.log("crv at reward pool " +a));
    await crv.balanceOf(cCrvRewards).then(a=>console.log("crv at cCrvRewards " +a));
    await crv.balanceOf(cvxRewards).then(a=>console.log("crv at cvxRewards " +a));
    await crv.balanceOf(userA).then(a=>console.log("userA crv: " +a))
    await rewardPool.earned(userA).then(a=>console.log("rewards earned(unclaimed): " +a));

    await bor.balanceOf(rewardStash.address).then(a=>console.log("bor on stash (==0): " +a));
    await bor.balanceOf(voteproxy.address).then(a=>console.log("bor on voter (==0): " +a));
    await bor.balanceOf(booster.address).then(a=>console.log("bor on deposit (==0): " +a));
    await bor.balanceOf(borRewards.address).then(a=>console.log("bor on rewards (>0): " +a));

    //claim crv reward pool, should also trigger cvx and bor
    await rewardPool.getReward({from:userA});
    console.log("getReward()");
    await crv.balanceOf(userA).then(a=>console.log("userA crv: " +a))
    await bor.balanceOf(userA).then(a=>console.log("userA bor: " +a))
    await cvx.balanceOf(userA).then(a=>console.log("userA cvx: " +a))

  });
});


