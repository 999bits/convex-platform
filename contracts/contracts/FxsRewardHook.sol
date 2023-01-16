// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

interface IFxsClaim{
    function claimFees(address _distroContract, address _token) external;
}
interface IFxsProxy{
    function operator() external view returns(address);
}

//hook that claims vefxs fees
contract FXSRewardHook{

    address public constant voteproxy = address(0x59CFCD384746ec3035299D90782Be065e466800B);
    address public constant fxs = address(0x3432B6A60D23Ca0dFCa7761B7ab56459D9C964D0);
    address public constant distro = address(0xc6764e58b36e26b08Fd1d2AeD4538c02171fA872);
    address public constant stash = address(0x4f3AD55D7b884CDC48ADD1e2451A13af17887F26);
    address public constant hookManager = address(0x723f9Aa67FDD9B0e375eF8553eB2AFC28eCD4a96);
    address public constant owner = address(0xa3C5A1e09150B75ff251c1a7815A07182c3de2FB);

    constructor() public {}

    function getReward(address _account) external{
        require(msg.sender == hookManager,"!auth");

        //ask the current operator to claim fees
        IFxsClaim( IFxsProxy(voteproxy).operator() ) .claimFees(distro,fxs);

        //check if any fxs made its way here by other means
        uint256 bal = IERC20(fxs).balanceOf(address(this));
        if(bal > 0){
            IERC20(fxs).transfer(stash,bal);
        }
    }

    function recoverERC20(address _tokenAddress, uint256 _tokenAmount, address _withdrawTo) external{
        require(msg.sender == owner, "!auth");
        require(_tokenAddress != fxs, "protected");
        IERC20(_tokenAddress).transfer(_withdrawTo, _tokenAmount);
    }

}