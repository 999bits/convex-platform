// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import "./Interfaces.sol";
import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/utils/Address.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';


contract ConvexToken is ERC20{
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    address public operator;
    address public vecrvProxy;

    uint256 public maxSupply = 10000000 * 1e18; //10mil
    uint256 public totalCliffs = 200;
    uint256 public reductionPerCliff;

    constructor(address _proxy)
        public
        ERC20(
            "Convex Token",
            "CVX"
        )
    {
        operator = msg.sender;
        vecrvProxy = _proxy;
        reductionPerCliff = maxSupply.div(totalCliffs);
    }

    //get current operator off proxy incase there was a change
    function updateOperator() public {
        operator = IStaker(vecrvProxy).operator();
    }
    
    function mint(address _to, uint256 _amount) external {
        if(msg.sender != operator){
            //dont error just return. if a shutdown happens, rewards on old system
            //can still be claimed, just wont mint cvx
            return;
        }

        if(totalSupply() == 0){
            //premine, one time only
            _mint(_to,_amount);
            //automatically switch operators
            updateOperator();
            return;
        }
        
        //determine current cliff based on what will be new supply
        uint256 newSupply = totalSupply().add(_amount);
        uint256 cliff = newSupply.div(reductionPerCliff);
        //mint if below total cliffs
        if(cliff < totalCliffs){
            //for reduction% take inverse of current cliff
            uint256 reduction = totalCliffs.sub(cliff);
            //reduce
            _amount = _amount.mul(reduction).div(totalCliffs);
            //mint
            _mint(_to, _amount);
        }
    }

}