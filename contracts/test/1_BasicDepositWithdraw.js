const { BN, constants, expectEvent, expectRevert, time } = require('openzeppelin-test-helpers');

const Booster = artifacts.require("Booster");
const CrvDepositor = artifacts.require("CrvDepositor");
const CurveVoterProxy = artifacts.require("CurveVoterProxy");
const ExtraRewardStashV2 = artifacts.require("ExtraRewardStashV2");
const ManagedRewardPool = artifacts.require("ManagedRewardPool");
const VirtualBalanceRewardPool = artifacts.require("VirtualBalanceRewardPool");
const cCrvRewardPool = artifacts.require("cCrvRewardPool");
const cvxRewardPool = artifacts.require("cvxRewardPool");
const ConvexToken = artifacts.require("ConvexToken");
const cCrvToken = artifacts.require("cCrvToken");
const StashFactory = artifacts.require("StashFactory");
const RewardFactory = artifacts.require("RewardFactory");

const IExchange = artifacts.require("IExchange");
const ICurveFi = artifacts.require("I3CurveFi");
const IERC20 = artifacts.require("IERC20");


contract("BasicDepositWithdraw", async accounts => {
  it("should test basic deposits and withdrawals", async () => {
    
    let crv = await IERC20.at("0xD533a949740bb3306d119CC777fa900bA034cd52");
    let weth = await IERC20.at("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2");
    let dai = await IERC20.at("0x6b175474e89094c44da98b954eedeac495271d0f");
    let exchange = await IExchange.at("0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D");
    let threecrvswap = await ICurveFi.at("0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7");
    let threeCrv = await IERC20.at("0x6c3F90f043a72FA612cbac8115EE7e52BDe6E490");
    let threeCrvGauge = "0xbFcF63294aD7105dEa65aA58F8AE5BE2D9d0952A";
    let threeCrvSwap = "0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7";
    let vecrvFeeDistro = "0xA464e6DCda8AC41e03616F95f4BC98a13b8922Dc";

    let admin = accounts[0];
    let userA = accounts[1];
    let userB = accounts[2];
    let caller = accounts[3];

    //system setup
    let voteproxy = await CurveVoterProxy.deployed();
    let booster = await Booster.deployed();
    let voterewardFactoryproxy = await RewardFactory.deployed();
    let stashFactory = await StashFactory.deployed();
    let cvx = await ConvexToken.deployed();
    let cCrv = await cCrvToken.deployed();
    let crvDeposit = await CrvDepositor.deployed();
    let cCrvRewards = await booster.lockRewards();
    let cvxRewards = await booster.stakerRewards();

    let poolinfo = await booster.poolInfo(0);
    let rewardPoolAddress = poolinfo.crvRewards;
    let rewardPool = await ManagedRewardPool.at(rewardPoolAddress);
    console.log("pool lp token " +poolinfo.lptoken);
    console.log("pool gauge " +poolinfo.gauge);
    console.log("pool reward contract at " +rewardPool.address);
    let starttime = await time.latest();
    console.log("current block time: " +starttime)

    //exchange weth for dai
    await weth.sendTransaction({value:web3.utils.toWei("2.0", "ether"),from:userA});
    let startingWeth = await weth.balanceOf(userA);
    await weth.approve(exchange.address,startingWeth,{from:userA});
    await exchange.swapExactTokensForTokens(startingWeth,0,[weth.address,dai.address],userA,starttime+3000,{from:userA});
    let startingDai = await dai.balanceOf(userA);

    //deposit dai for 3crv
    await dai.approve(threecrvswap.address,startingDai,{from:userA});
    await threecrvswap.add_liquidity([startingDai,0,0],0,{from:userA});
    let startingThreeCrv = await threeCrv.balanceOf(userA);
    console.log("3crv: " +startingThreeCrv);
 
    //approve
    await threeCrv.approve(booster.address,0,{from:userA});
    await threeCrv.approve(booster.address,startingThreeCrv,{from:userA});

    //first try depositing too much
    console.log("try depositing too much");
    await expectRevert(
        booster.deposit(0,startingThreeCrv+1,{from:userA}),
        "SafeERC20");
    console.log(" ->reverted");

    //deposit a small portion
    await booster.deposit(0,web3.utils.toWei("500.0", "ether"),{from:userA});
    console.log("deposited portion");

    //check wallet balance and deposit credit
    await threeCrv.balanceOf(userA).then(a=>console.log("wallet balance: " +a));
    await booster.userPoolInfo(0,userA).then(a=>console.log("lp balance: " +a));

    //deposit reset of funds
    await booster.depositAll(0,{from:userA});
    console.log("deposited all");

    //check wallet balance and deposit credit
    await threeCrv.balanceOf(userA).then(a=>console.log("wallet balance: " +a));
    await booster.userPoolInfo(0,userA).then(a=>console.log("lp balance: " +a));

    //check that deposit is also reflected on reward contract
    await rewardPool.balanceOf(userA).then(a=>console.log("reward balance: " +a));

    //withdraw a portion
    await booster.withdraw(0,web3.utils.toWei("500.0", "ether"),{from:userA});

    //check wallet increased and that deposit credit/reward balance decreased
    await threeCrv.balanceOf(userA).then(a=>console.log("wallet balance: " +a));
    await booster.userPoolInfo(0,userA).then(a=>console.log("lp balance: " +a));
    await rewardPool.balanceOf(userA).then(a=>console.log("reward balance: " +a));

    //withdraw too much error check
    // this will error on the gauge not having enough balance
    console.log("try withdraw too much");
    await expectRevert(
        booster.withdraw(0,startingThreeCrv+1,{from:userA}),
        "revert");
    console.log(" ->reverted (fail on unstake)");


    ///add funds for user B
    await weth.sendTransaction({value:web3.utils.toWei("2.0", "ether"),from:userB});
    await weth.approve(exchange.address,web3.utils.toWei("2.0", "ether"),{from:userB});
    await exchange.swapExactTokensForTokens(web3.utils.toWei("2.0", "ether"),0,[weth.address,dai.address],userB,starttime+3000,{from:userB});
    let userBDai = await dai.balanceOf(userB);
    await dai.approve(threecrvswap.address,userBDai,{from:userB});
    await threecrvswap.add_liquidity([userBDai,0,0],0,{from:userB});
    let userBThreeCrv = await threeCrv.balanceOf(userB);
    await threeCrv.approve(booster.address,0,{from:userB});
    await threeCrv.approve(booster.address,userBThreeCrv,{from:userB});
    await booster.depositAll(0,{from:userB});
    await booster.userPoolInfo(0,userB).then(a=>console.log("user b deposits: " +a));

    //withdraw too much error check again
    // this will error on the deposit balance not being high enough (gauge balance check passes though because of userB)
    console.log("try withdraw too much(2)");
    await expectRevert(
        booster.withdraw(0,startingThreeCrv+1,{from:userA}),
        "revert");
    console.log(" ->reverted (fail on user funds)");


    //withdraw all properly
    await booster.withdrawAll(0,{from:userA});
    console.log("withdrawAll");

    //all balance should be back on wallet and equal to starting value
    await threeCrv.balanceOf(userA).then(a=>console.log("wallet balance: " +a));
    await booster.userPoolInfo(0,userA).then(a=>console.log("lp balance: " +a));
    await rewardPool.balanceOf(userA).then(a=>console.log("reward balance: " +a));
  });
});


