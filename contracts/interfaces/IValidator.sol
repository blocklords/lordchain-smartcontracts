// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IValidator {
    error NotAdmin();
    error NotOwner();
    error FeeTooHigh();
    error ZeroFee();
    error ZeroAmount();
    error ZeroDuration();
    error InvalidLockDuration();
    error AllreadyLocked();
    error NoLockCreated();
    error NoStakeFound();
    error InsufficientAmount();
    error TimeNotUp();
    error NotEnoughStakeToken();
    error NotEnoughRewardToken();
    error FactoryAlreadySet();

    event ClaimFees(address indexed sender, uint256 amount);
    event Deposit(address indexed sender, uint256 amount, uint256 duration, uint256 endTime);
    event Claim(address indexed sender, uint256 userClaimAmount, uint256 feeAmount);
    event Withdraw(address indexed sender, uint256 amount, uint256 userClaimAmount, uint256 feeAmount);

    /// @notice Claim accumulated but unclaimed fees
    function claimFees() external;

    /// @notice Address of token in the pool with the lower address value
    function token() external view returns (address);

    /// @notice Address of linked validatorFees.sol
    function validatorFees() external view returns (address);

    /// @notice Address of PoolFactory that created this contract
    function factory() external view returns (address);

    function initialize(address _admin, address _token, address _owner, uint256 _validatorId) external;
}