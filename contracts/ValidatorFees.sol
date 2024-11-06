// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ValidatorFees
contract ValidatorFees {
    using SafeERC20 for IERC20;
    address internal immutable validator; // The validator it is bonded to
    address internal token; // token of validator, saved localy and statically for gas optimization

    error NotValidator();
    error ZeroFee();

    constructor() {
        validator = msg.sender;
    }

    /// @notice Allow the validator to transfer fees to users
    function claimFeesFor(address _recipient) external returns (uint256 claimed){
        if (msg.sender != validator) revert NotValidator();
        
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) revert ZeroFee();
        
        IERC20(token).safeTransfer(_recipient, balance);

        claimed = balance;
    }

    function setToken(address _token) external {
        if (msg.sender != validator) revert NotValidator();

        token = _token;
    }
    
}