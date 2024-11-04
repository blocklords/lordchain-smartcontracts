// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IValidator {
    
    error NotAdmin();
    error NotOwner();
    error FeeTooHigh();
    error WrongFee();
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
    error InvalidTotalReward();
    error StartTimeNotInFuture();
    error EndTimeBeforeStartTime();
    error StartTimeNotAsExpected();
    error RewardPeriodNotActive();
    error GreaterThenMaxTime();
    error TheSameValue();
    error AutoMaxTime();
    error QualityWrong();
    error SignatureExpired();
    error ValidatorIsClaimed();
    error ZeroAddress();
    error VerificationFailed();
    error AutoMaxNotEnabled();

    event ClaimFees(address indexed sender, uint256 amount);
    event Deposit(address indexed sender, uint256 amount, uint256 duration, uint256 endTime);
    event Claim(address indexed sender, uint256 userClaimAmount, uint256 feeAmount);
    event Withdraw(address indexed sender, uint256 amount, uint256 userClaimAmount, uint256 feeAmount);
    event SetAutoMax(address indexed sender, bool open);
    event PurchaseValidator(address indexed sender, uint256 NP);
    event SetDepositFee(address indexed sender, uint256 fee);
    event SetClaimFee(address indexed sender, uint256 fee);

    /// @notice Claims accumulated fees for the contract owner.
    /// @dev Only the owner can call this function to claim fees.
    function claimFees() external;

    /// @notice Address of token in the pool with the lower address value
    function token() external view returns (address);

    /// @notice Address of linked validatorFees.sol
    function validatorFees() external view returns (address);

    /// @notice Address of PoolFactory that created this contract
    function factory() external view returns (address);

    /// @notice Initializes the Validator contract with necessary parameters.
    /// @param _admin The address of the admin who can manage the contract.
    /// @param _token The address of the token that users will stake.
    /// @param _owner The address of the contract owner.
    /// @param _validatorId The unique identifier for the validator.
    /// @param _isClaimed Whether the validator is purchased.
    /// @dev This function can only be called once to set up the contract.
    function initialize(address _admin, address _token, address _owner, uint256 _validatorId, bool _isClaimed, uint256 _quality) external;

    /// @notice Creates a new lock for a specified amount of tokens with a defined duration.
    /// @param _amount The amount of tokens to lock.
    /// @param _lockDuration The duration for which the tokens will be locked.
    /// @dev The lock duration must be valid and the reward period must be active.
    function createLock(uint256 _amount, uint256 _lockDuration) external;
    
    /// @notice Increases the amount of staked tokens in the existing lock.
    /// @param _amount The additional amount of tokens to stake.
    /// @dev The reward period must be active to increase the amount.
    function increaseAmount(uint256 _amount) external;
    
    /// @notice Extends the lock duration of the staked tokens.
    /// @param _lockDuration The new duration to extend the lock.
    /// @dev The reward period must be active to extend the duration.
    function extendDuration(uint256 _lockDuration) external;
    
    /// @notice Withdraws staked tokens and claims rewards.
    /// @dev Users can only withdraw after the lock duration has expired.
    function withdraw() external;
    
    /// @notice Claims rewards for the user based on the staked amount;
    /// @dev Users can claim rewards as long as the reward period is active.
    function claim() external;

    function setAutoMax(bool _bool) external;

    function getAmountAndAutoMax(address _userAddress) external view returns (uint256, bool);
}