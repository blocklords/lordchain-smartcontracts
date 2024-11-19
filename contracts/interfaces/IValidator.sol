// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IValidator {

    error NotAdmin();
    error NotOwner();
    error NotFactory();
    error NotGovernance();
    error FeeTooHigh();
    error WrongFee();
    error ZeroAmount();
    error AllreadyLocked();
    error NoLockCreated();
    error InsufficientAmount();
    error TimeNotUp();
    error NotEnoughStakeToken();
    error NotEnoughRewardToken();
    error FactoryAlreadySet();
    error InvalidTotalReward();
    error StartTimeNotInFuture();
    error EndTimeBeforeStartTime();
    error StartTimeNotAsExpected();
    error TheSameValue();
    error AutoMaxTime();
    error QualityWrong();
    error SignatureExpired();
    error ValidatorIsClaimed();
    error ZeroAddress();
    error VerificationFailed();
    error AutoMaxNotEnabled();
    error WrongDuration();
    error LockTimeExceeded();
    error ContractPaused();
    error StateUnchanged();
    error InvalidBoostReward();
    error NoReward();
    error AlreadyPurchasedThisQuality();
    error InsufficientNPPoint();
    error InsufficientLockAmount();
    error GreaterThanMaxTime();
    error NotValidValidator();

    event ClaimFees(address indexed sender, uint256 amount);
    event Deposit(address indexed sender, uint256 amount, uint256 duration, uint256 endTime);
    event Claim( address indexed sender, uint256 userClaimAmount, uint256 feeAmount);
    event Withdraw( address indexed sender, uint256 amount);
    event SetAutoMax(address indexed sender, bool open);
    event PurchaseValidator(address indexed sender, uint256 NP, uint256 quality);
    event SetDepositFee(address indexed sender, uint256 fee);
    event SetClaimFee(address indexed sender, uint256 fee);
    event BoostRewardAdded(uint256 startTime, uint256 endTime, uint256 totalReward);
    event BoostRewardClaimed(address indexed sender, uint256 pendingBoostReward);
    event StakeForUser(address indexed sender, uint256 amount);

    /// @notice Returns the address of the PoolFactory that created this contract.
    /// @dev This function returns the address of the `PoolFactory` contract, which is responsible for deploying and managing the pool contract.
    /// @return address The address of the PoolFactory contract that created this contract.
    function factory() external view returns (address);

    /// @notice Initializes the Validator contract with necessary parameters.
    /// @param _token The address of the LRDS.
    /// @param _admin The address of the admin who can manage the contract.
    /// @param _owner The address of the contract owner who can claim rewards and manage the pool.
    /// @param _validatorId The unique identifier for the validator. This will help distinguish different validators in the system.
    /// @param _quality The quality level of the validator (used for ranking or other features).
    /// @param _verifier The address of the verifier.
    /// @param _currentQualityCount The address of the verifier.
    /// @dev This function can only be called once during the initialization phase to set up the validator contract with all necessary parameters.
    function initialize(address _token, address _admin, address _owner, uint256 _validatorId, uint256 _quality, address _verifier, uint256 _currentQualityCount) external;

    /// @notice Creates a new lock for a specified amount of tokens with a defined duration.
    /// @param _amount The amount of tokens to lock for the specified duration.
    /// @param _lockDuration The duration for which the tokens will be locked (in seconds).
    /// @dev The lock duration must be valid and the reward period must be active to perform this action. 
    /// Users will not be able to unlock their tokens before the lock duration has passed.
    function createLock(uint256 _amount, uint256 _lockDuration) external;
        
    /// @notice Increases the amount of staked tokens in the existing lock.
    /// @param _amount The additional amount of tokens to stake. 
    /// @dev The reward period must be active for the increase to take effect. 
    /// This function allows users to add tokens to their current lock without creating a new lock.
    function increaseAmount(uint256 _amount) external;
        
    /// @notice Extends the lock duration of the staked tokens.
    /// @param _lockDuration The new duration to extend the lock (in seconds).
    /// @dev The reward period must be active for the extension to occur. Users can extend their token lock period, but they cannot shorten it.
    function extendDuration(uint256 _lockDuration) external;
        
    /// @notice Withdraws staked tokens and claims rewards.
    /// @dev Users can only withdraw their tokens after the lock duration has expired. 
    /// This function transfers the staked tokens back to the user and also releases any accumulated rewards.
    function withdraw() external;
        
    /// @notice Claims rewards for the user based on the staked amount.
    /// @dev Users can claim rewards as long as the reward period is still active. Rewards are typically proportional to the amount staked.
    function claim() external;

    /// @notice Sets whether the maximum staking amount should be automatically adjusted.
    /// @param _bool A boolean indicating whether to automatically adjust the maximum staking amount for the user.
    /// @dev This function allows the contract owner or admin to enable or disable the automatic adjustment of the maximum staking amount.
    function setAutoMax(bool _bool) external;

    /// @notice Returns the amount staked by a user and whether automatic max staking adjustment is enabled.
    /// @param _userAddress The address of the user whose staking information is to be retrieved.
    /// @return uint256 The total amount staked by the user.
    /// @return bool A boolean indicating whether the automatic max staking adjustment is enabled for this user.
    function getAmountAndAutoMax(address _userAddress) external view returns (uint256, bool);

    /// @notice Returns the veLrds balance of a user.
    /// @param _user The address of the user whose veLrds balance is to be retrieved.
    /// @return uint256 The amount of veLrds tokens held by the user. 
    /// This is typically used to calculate voting or staking power in governance-related systems.
    function veLrdsBalance(address _user) external view returns (uint256);

    /// @notice Returns whether the validator has been purchased or activated.
    /// @return bool A boolean indicating whether the validator has been purchased (true) or not (false).
    function isClaimed() external view returns (bool);
        
    /// @notice Adds a boost reward for a specific validator within a defined time period.
    /// @param _startTime The start time of the boost period.
    /// @param _endTime The end time of the boost period.
    /// @param _rewardAmount The total amount of reward to be distributed to the validator during the boost period.
    /// @dev This function allows the contract to assign a reward to a validator within a specific time window.
    function addBoostReward(uint256 _startTime, uint256 _endTime, uint256 _rewardAmount) external;

    /// @dev Allows the Governance contract to stake tokens on behalf of a user.
    /// This function can only be called by the authorized Governance contract.
    /// It increases the user's staked balance by the specified amount.
    /// @param _user The address of the user for whom tokens are being staked.
    /// @param _amount The amount of tokens to stake for the user.
    /// @param _fromBoost Whether the boost reward deposit.
    function stakeFor(address _user, uint256 _amount, bool _fromBoost) external;

    /// @dev Checks whether a user has already purchased a validator of a specific quality.
    /// @param _user The address of the user to check.
    /// @param _quality The quality level of the validator.
    /// @return A boolean value indicating whether the user has purchased a validator of the specified quality.
    function havePurchased(address _user, uint256 _quality) external view returns (bool);

    /// @dev Retrieves the total cost of validators associated with a specific user.
    /// @param _user The address of the user to retrieve the total validator cost for.
    /// @return The total cost of validators for the specified user.
    function playerValidatorCosts(address _user) external view returns (uint256);

    /// @dev Updates the purchase status for a specific user and validator quality.
    ///      This function can only be called by a valid Validator contract,
    ///      as ensured by the `onlyValidValidator` modifier.
    /// @param _user The address of the user whose purchase status is being updated.
    /// @param _quality The quality level of the validator being purchased.
    function _updateHavePurchased(address _user, uint256 _quality) external;

    /// @dev Updates the total cost of player validators for a specific user.
    ///      This function can only be called by a valid Validator contract,
    ///      as ensured by the `onlyValidValidator` modifier.
    /// @param _user The address of the user whose total validator cost is being updated.
    /// @param _cost The cost to be added to the user's total validator cost.
    function _updatePlayerValidatorCost(address _user, uint256 _cost) external;

}
