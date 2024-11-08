// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";


import "./interfaces/IValidatorFactory.sol";
import "./interfaces/IValidator.sol";
import "./interfaces/IGovernance.sol";
import "./ValidatorFees.sol";

/// @title Validator Contract
/// @notice This contract allows users to stake tokens, manage reward periods, and claim rewards.
/// @dev The contract uses ERC20 and includes reward management for staked tokens.

contract Validator is IValidator, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // RewardPeriod struct is used to record the details of a reward period
    struct RewardPeriod {
        uint256 startTime;          // The start time of the reward period
        uint256 endTime;            // The end time of the reward period
        address stakeToken;         // The address of the token that users stake
        address rewardToken;        // The address of the token that is used as the reward
        uint256 totalReward;        // The total reward amount for this period
        uint256 accTokenPerShare; // The accumulated tokens per share for this reward period
    }

    // UserInfo struct is used to store staking information for each user
    struct UserInfo {
        uint256 amount;             // The amount of tokens the user has staked
        uint256 lockStartTime;      // The start time of the staking lock period
        uint256 lockEndTime;        // The end time of the staking lock period
        uint256 rewardDebt;         // The reward debt, used to calculate the user's reward share
        uint256 lastUpdatedRewardPeriod; // The index of the last reward period in which rewards were calculated for the user
        bool autoMax;               // Indicates whether the user has enabled automatic maximum staking
    }

    uint256 public constant DEPOSIT_MAX_FEE = 100;          // The maximum deposit fee (1%)
    uint256 public constant CLAIM_MAX_FEE = 500;            // The maximum claim fee (5%)
    uint256 public constant WEEK = 7 days;                  // One week in seconds
    // uint256 public constant MAX_LOCK = (209 * WEEK) - 1;    // Maximum lock duration (209 weeks - 1 second)
    // uint256 public constant MIN_LOCK = WEEK;             // Minimum lock duration (520 seconds) --> main
    uint256 public constant MAX_LOCK = 14560;    // Maximum lock duration (209 weeks - 1 second)
    uint256 public constant MIN_LOCK = 520;                 // Minimum lock duration (520 seconds) -->test
    uint256 public constant MULTIPLIER = 10**18;            // The precision factor for reward calculations

    bool public isClaimed;                                  // Flag to indicate whether the validator has been claimed
    bool public isPaused;                                   // Flag to indicate whether the contract is paused

    string public _name;                                    // The name of the validator contract

    uint256 public lastRewardTime;                          // The last time rewards were distributed
    uint256 public totalStaked;                             // The total amount of staked tokens
    uint256 public PRECISION_FACTOR;                        // The precision factor for reward calculations
    uint256 public depositFee;                              // The deposit fee percentage
    uint256 public claimFee;                                // The claim fee percentage
    uint256 public validatorId;                             // The unique identifier of the validator
    uint256 public currentRewardPeriodIndex;                // The current reward period index
    uint256 public quality;                                 // The quality level of the validator (e.g., Master, Super, etc.)

    /// @inheritdoc IValidator
    address public validatorFees;                           // The address of the validator fees contract
    /// @inheritdoc IValidator
    address public factory;                                 // The address of the PoolFactory that created this contract
    address private voter;                                  // The address of the voter (for validation purposes)
    address public admin;                                   // The address of the contract admin
    address public owner;                                   // The address of the contract owner
    address public verifier;                                // The address of the verifier for signature verification
    address public masterValidator;                         // The address of the master validator contract

    // Mapping to store reward periods
    mapping(uint256 => RewardPeriod) public rewardPeriods;
    // Mapping to store information about each user who stakes tokens
    mapping(address => UserInfo) public userInfo;
    // Mapping to store the count of nodes based on their quality
    mapping(uint256 => uint256) public nodeCounts;

    // Modifier to ensure only the admin can access the function
    modifier onlyAdmin() {
        if (msg.sender != address(admin)) revert NotAdmin();
        _;
    }

    // Modifier to ensure only the owner can access the function
    modifier onlyOwner() {
        if (msg.sender != address(admin)) revert NotOwner();
        _;
    }

    // Modifier to ensure the contract is not paused
    modifier whenNotPaused() {
        if (isPaused) revert ContractPaused();
        _;
    }

    // Modifier to ensure only the factory can access the function
    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    constructor() {}

    /// @inheritdoc IValidator
    function initialize(
        address _admin,
        address _owner,
        uint256 _validatorId,
        uint256 _quality,
        address _verifier
    ) external nonReentrant {
        if (factory != address(0)) revert FactoryAlreadySet();
        factory = msg.sender;
        voter = IValidatorFactory(factory).voter();
        (admin, owner, validatorId, quality) = (_admin, _owner, _validatorId, _quality);
        if (_quality < 1 && _quality > 7) revert QualityWrong();
        PRECISION_FACTOR = 10 ** 12;

        validatorFees = address(new ValidatorFees());

        string[7] memory nodeTypes = [
            "BLOCKLORDS Master",      // index 0, quality 1
            "Super Validator",        // index 1, quality 2
            "Basic Validator",        // index 2, quality 3
            "Special Validator",      // index 3, quality 4
            "Rare Validator",         // index 4, quality 5
            "Epic Validator",         // index 5, quality 6
            "Legendary Validator"     // index 6, quality 7
        ];

        string memory nodeType = nodeTypes[_quality - 1];

        if (_quality == 1) {
            depositFee = 0;
            claimFee   = 0;
            _name      = nodeType;
            isClaimed  = true;
        } else {
            depositFee = 100; // 1%
            claimFee   = 500; // 5%
            _name      = string(abi.encodePacked(nodeType, " ", Strings.toString(nodeCounts[_quality])));
            isClaimed  = false;
            nodeCounts[_quality]++;
        }
        verifier = _verifier;
        isPaused = false;
    }

    /// @notice Sets a new reward period for staking.
    /// @param _startTime The start time of the reward period (must be in the future).
    /// @param _endTime The end time of the reward period (must be after start time).
    /// @param _stakeToken The address of the token that users will stake.
    /// @param _rewardToken The address of the token that will be rewarded.
    /// @param _totalReward The total amount of reward tokens available for this period.
    /// @dev This function can only be called by the admin.
    function setRewardPeriod(
        uint256 _startTime,
        uint256 _endTime,
        address _stakeToken,
        address _rewardToken,
        uint256 _totalReward
    ) external nonReentrant onlyAdmin {

        ValidatorFees(validatorFees).setToken(_stakeToken);

        // Check if total reward is greater than 0
        if (_totalReward <= 0) revert InvalidTotalReward();

        // If it's the first reward period
        if (currentRewardPeriodIndex == 0) {
            // Start time should be in the future
            if (_startTime <= block.timestamp) revert StartTimeNotInFuture();
            // End time should be after start time
            if (_endTime <= _startTime) revert EndTimeBeforeStartTime();
        } else {
            // For subsequent reward periods, start time should be the end time of the previous period
            RewardPeriod memory previousPeriod = rewardPeriods[currentRewardPeriodIndex - 1];
            if (_startTime != previousPeriod.endTime) revert StartTimeNotAsExpected();
        }

        rewardPeriods[currentRewardPeriodIndex++] = RewardPeriod({
            startTime: _startTime,
            endTime: _endTime,
            stakeToken: _stakeToken,
            rewardToken: _rewardToken,
            totalReward: _totalReward,
            accTokenPerShare: 0
        });
        
        IValidatorFactory(factory).AddTotalValidators(_startTime, _endTime, _totalReward);
    }

    /*//////////////////////////////////////////////////////////////
                               VALIDATOR
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IValidator
    function createLock(uint256 _amount, uint256 _lockDuration) external nonReentrant whenNotPaused {
        if (_amount == 0) revert ZeroAmount();
        if (_lockDuration == 0 || _lockDuration < MIN_LOCK || _lockDuration > MAX_LOCK) revert WrongDuration();
        if (!_isRewardPeriodActive()) revert RewardPeriodNotActive();

        UserInfo storage user = userInfo[msg.sender];
        if (user.amount > 0 || user.lockStartTime > 0) revert AllreadyLocked();

        IValidatorFactory(factory).AddTotalStakedWallet();

        _deposit(_amount, _lockDuration, user);
    }

    /// @inheritdoc IValidator
    function increaseAmount(uint256 _amount) external nonReentrant whenNotPaused {
        if (_amount == 0) revert ZeroAmount();
        if (!_isRewardPeriodActive()) revert RewardPeriodNotActive();

        UserInfo storage user = userInfo[msg.sender];
        if (user.amount == 0) revert NoLockCreated();
        if (user.autoMax == false) {
            if (block.timestamp > user.lockEndTime) revert LockTimeExceeded();
        }

        _deposit(_amount, 0, user);
    }

    /// @inheritdoc IValidator
    function extendDuration(uint256 _lockDuration) external nonReentrant whenNotPaused {
        if (_lockDuration <= 0 || _lockDuration > MAX_LOCK) revert WrongDuration();
        if (!_isRewardPeriodActive()) revert RewardPeriodNotActive();

        UserInfo storage user = userInfo[msg.sender];
        if (user.amount == 0) revert NoLockCreated();
        if (user.autoMax == true) revert AutoMaxTime();

        uint256 newEndTime;
        if (block.timestamp > user.lockEndTime) {
            // If lock has already expired, start from current time
            newEndTime = block.timestamp + _lockDuration;
        } else {
            // Otherwise, extend from the current lock end time
            newEndTime = user.lockEndTime + _lockDuration;
        }

        if (newEndTime > block.timestamp + MAX_LOCK) revert("GreaterThanMaxTime");

        _deposit(0, _lockDuration, user);
    }

    /// @inheritdoc IValidator
    function claim() external nonReentrant whenNotPaused {
        if (!_isRewardPeriodActive()) revert RewardPeriodNotActive();

        UserInfo storage user = userInfo[msg.sender];

        if (user.amount == 0) revert NoStakeFound();

        // Update global reward state and user-specific rewards
        _updateValidator();
        _updateUserRewards(user);

        // Calculate the total pending rewards
        uint256 totalPending = _calculateTotalPending(user);

        // Call _claim to distribute the rewards
        (uint256 userClaimAmount, uint256 feeAmount) = _claim(totalPending);
        
        user.rewardDebt = (user.amount * rewardPeriods[currentRewardPeriodIndex - 1].accTokenPerShare) / PRECISION_FACTOR;

        // Update the user's last updated reward period to the current period
        user.lastUpdatedRewardPeriod = currentRewardPeriodIndex - 1;

        emit Claim(msg.sender, userClaimAmount, feeAmount);
    }

    /// @inheritdoc IValidator
    function withdraw() external nonReentrant whenNotPaused {
        UserInfo storage user = userInfo[msg.sender];

        if (user.amount == 0) revert ZeroAmount();
        if (block.timestamp < user.lockEndTime) revert TimeNotUp();
        if (user.autoMax == true) revert AutoMaxTime();

        // Update global reward state and user-specific rewards
        _updateValidator();
        _updateUserRewards(user);

        if (IERC20(rewardPeriods[currentRewardPeriodIndex - 1].stakeToken).balanceOf(address(this)) < user.amount) revert NotEnoughStakeToken();

        // Calculate the total pending rewards
        uint256 totalPending = _calculateTotalPending(user);

        // Call _claim to distribute the rewards
        (uint256 userClaimAmount, uint256 feeAmount) = _claim(totalPending);

         // Transfer the user's staked amount back to them
        IERC20(rewardPeriods[currentRewardPeriodIndex - 1].stakeToken).safeTransfer(address(msg.sender), user.amount);

        // Reset the user's reward debt to zero after withdrawing
        user.rewardDebt = 0;

        // Reset votes associated with the user
        IGovernance(voter).resetVotes(msg.sender);

        // Update the global staking total
        totalStaked -= user.amount;

        // Remove the user's information from the contract
        delete userInfo[msg.sender];

        // Update the total staked amount and wallet count in the factory contract
        IValidatorFactory(factory).SubTotalStakedAmount(user.amount);
        IValidatorFactory(factory).SubTotalStakedWallet();

        emit Withdraw(msg.sender, user.amount, userClaimAmount, feeAmount);
    }
    
    /// @inheritdoc IValidator
    function setAutoMax(bool _bool) external nonReentrant whenNotPaused {
        UserInfo storage user = userInfo[msg.sender];
        if (user.amount == 0) revert NoLockCreated();
        if (user.autoMax == _bool) revert TheSameValue();
        user.autoMax = _bool;
        user.lockEndTime = block.timestamp + MAX_LOCK;

        emit SetAutoMax(msg.sender, _bool);
    }

    /// @notice Allows a user to purchase a validator by providing a signature and other required parameters.
    /// @dev This function verifies that the provided signature is valid, ensures the user has sufficient funds,
    ///      and that certain conditions are met before claiming the validator.
    /// @param _np The number of validators being purchased (may represent quantity or other related value).
    /// @param _quality The quality level of the validator.
    /// @param _deadline The deadline by which the transaction must be completed, used to prevent replay attacks. uint256 ,
    /// @param _v The recovery byte of the signature.
    /// @param _r The 'r' part of the ECDSA signature.
    /// @param _s The 's' part of the ECDSA signature.
    /// @dev This function ensures that only authorized users can purchase the validator and that they meet
    ///      the necessary requirements for purchasing.
    function purchaseValidator(uint256 _np, uint256 _quality, uint256 _deadline, uint8 _v,  bytes32 _r, bytes32 _s) external nonReentrant whenNotPaused {
        // Check that the deadline has not passed, ensuring the signature is still valid
        if (_deadline < block.timestamp) revert SignatureExpired();

        // Ensure that the number of validators to be purchased is greater than 0
        if (_np <= 0) revert InsufficientAmount();

        if (_quality != quality) revert QualityWrong();

        // Ensure that the validator has not already been claimed
        if (isClaimed == true) revert ValidatorIsClaimed();

        // Retrieve the amount of tokens and the auto-max setting from the master validator contract
        (uint256 amount, bool isAutoMax) = IValidator(masterValidator).getAmountAndAutoMax(msg.sender);

        // Ensure that auto-max is enabled for the user (this flag must be true to proceed)
        if (isAutoMax == false) revert AutoMaxNotEnabled();

        // Check that the user has staked enough tokens to meet the required minimum amount for the given quality
        uint256 requiredAmount = IValidatorFactory(factory).minAmountForQuality(quality);
        if (amount < requiredAmount) revert InsufficientAmount();

        // Verify the signature by hashing the message and recovering the address
        {
            // Generate the message hash using the parameters
            bytes32 message = keccak256(abi.encodePacked(_np, address(this), _deadline, block.chainid, msg.sender, _quality));
            bytes32 hash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", message));
            
            // Recover the address from the signature
            address recover = ecrecover(hash, _v, _r, _s);

            // Ensure the recovered address matches the expected verifier address
            if (recover != verifier) revert VerificationFailed();
        }

        // Mark the validator as claimed and set the owner to the message sender
        isClaimed = true;
        owner = msg.sender;

        // Emit the PurchaseValidator event to notify that the purchase was successful
        emit PurchaseValidator(msg.sender, _np);
    }

    /// @notice Gets the pending rewards for a user.
    /// @param _userAddress The address of the user to query.
    /// @return The amount of pending rewards for the user.
    function getUserPendingReward(address _userAddress) external view returns (uint256) {
        UserInfo storage user = userInfo[_userAddress];
        return _calculateTotalPending(user);
    }

    /// @notice Calculates the total rewards for a validator based on the reward periods and current time.
    /// @dev This function iterates through all reward periods and calculates the rewards that have been earned,
    ///      considering the time elapsed in each period. Rewards are calculated based on the proportion of time
    ///      that has passed in each period relative to the total duration of the period.
    /// @return totalRewards The total rewards accumulated by the validator over all reward periods.
    function getValidatorRewards() external view returns (uint256) {
        uint256 totalRewards = 0;

        // Iterate through each reward period and calculate rewards for that period
        for (uint256 i = 0; i < currentRewardPeriodIndex; i++) {
            uint256 period = 0;

            // If the current block timestamp is greater than the reward period's start time
            if (block.timestamp > rewardPeriods[i].startTime) {
                period = block.timestamp - rewardPeriods[i].startTime;

                // Ensure the period doesn't exceed the end time of the reward period
                if (block.timestamp > rewardPeriods[i].endTime) {
                    period = rewardPeriods[i].endTime - rewardPeriods[i].startTime;
                }
            }

            uint256 duration = rewardPeriods[i].endTime - rewardPeriods[i].startTime;

            // Add the reward for this period, proportional to the time spent in the period
            totalRewards += (period * rewardPeriods[i].totalReward) / duration;
        }

        return totalRewards;
    }

    /// @notice Retrieves the amount of staked tokens and the auto-max setting for a user.
    /// @param _userAddress The address of the user whose staking information is to be retrieved.
    /// @return amount The amount of tokens the user has staked.
    /// @return isAutoMax Whether the auto-max feature is enabled for the user.
    function getAmountAndAutoMax(address _userAddress) external view returns (uint256, bool) {
        UserInfo storage info = userInfo[_userAddress];
        return (info.amount, info.autoMax);
    }

    /// @notice Handles the deposit of staked tokens into the contract for a user.
    /// @dev This function transfers tokens to the contract, applies the deposit fee, updates the user's staking amount,
    ///      and records the lock duration if specified. It also updates the total staked amount in the factory contract.
    /// @param _amount The amount of tokens the user wishes to deposit.
    /// @param _lockDuration The duration for which the tokens will be locked. If set to 0, the tokens will not be locked.
    /// @param _user The user information struct to be updated.
    function _deposit(uint256 _amount, uint256 _lockDuration, UserInfo storage _user) internal {
        // Update global reward state and user-specific rewards
        _updateValidator();
        _updateUserRewards(_user);

        if (_amount > 0) {
            // Calculate the deposit fee (depositFee is in basis points, e.g., 500 = 5%)
            uint256 fee = (_amount * depositFee) / 10000;
            uint256 amountAfterFee = _amount - fee;

            // Ensure the amount after fee is positive
            if (amountAfterFee <= 0) revert InsufficientAmount();

            // Transfer the staked amount to the contract
            IERC20(rewardPeriods[currentRewardPeriodIndex - 1].stakeToken).safeTransferFrom(msg.sender, address(this), amountAfterFee);

            // If there is a fee, transfer it to the validatorFees address
            if (fee > 0) {
                IERC20(rewardPeriods[currentRewardPeriodIndex - 1].stakeToken).safeTransferFrom(msg.sender, validatorFees, fee);
            }

            // Update the user's staked amount
            _user.amount += amountAfterFee;
            totalStaked  += amountAfterFee;

            // If a lock duration is provided, set the lock start and end times
            if (_lockDuration > 0) {
                _user.lockStartTime = block.timestamp;
                _user.lockEndTime = _lockDuration + block.timestamp;
            }

            // Update the total staked amount in the factory contract
            IValidatorFactory(factory).AddTotalStakedAmount(amountAfterFee);
        }

        // If lock duration is provided but no amount is being deposited, just extend the lock duration
        if (_lockDuration > 0 && _amount == 0) {
            _user.lockEndTime += _lockDuration;
        }

        _user.rewardDebt = (_user.amount * rewardPeriods[currentRewardPeriodIndex - 1].accTokenPerShare) / PRECISION_FACTOR;

        // Emit the Deposit event
        emit Deposit(msg.sender, _amount, _lockDuration, _user.lockEndTime);
    }

    /// @notice Claims the pending rewards for a user and transfers the reward amount.
    /// @dev This function calculates the pending rewards, applies the claim fee, and transfers the rewards to the user.
    ///      It also transfers the fee portion to the contract owner.
    /// @param _pending The amount of pending rewards to be claimed.
    /// @return userClaimAmount The amount of rewards the user can claim after the fee is deducted.
    /// @return feeAmount The amount of rewards deducted as a fee.
    function _claim(uint256 _pending) internal returns (uint256 userClaimAmount, uint256 feeAmount) {
        // If there are no pending rewards, return zero values
        if (_pending == 0) return (0, 0);

        // Ensure the contract has enough reward tokens to cover the pending claim
        if (IERC20(rewardPeriods[currentRewardPeriodIndex - 1].rewardToken).balanceOf(address(this)) < _pending) revert NotEnoughRewardToken();

        // Calculate the claim fee (claimFee is in basis points, e.g., 300 = 3%)
        feeAmount = (_pending * claimFee) / 10000;
        userClaimAmount = _pending - feeAmount;

        // Transfer the fee to the contract owner
        IERC20(rewardPeriods[currentRewardPeriodIndex - 1].rewardToken).safeTransfer(owner, feeAmount);

        // Transfer the remaining rewards to the user
        IERC20(rewardPeriods[currentRewardPeriodIndex - 1].rewardToken).safeTransfer(msg.sender, userClaimAmount);
    }

    /// @notice Calculates the total pending rewards for a user across all eligible reward periods.
    /// @param user The UserInfo struct of the user.
    /// @return totalPending The total amount of pending rewards for the user.
    function _calculateTotalPending(UserInfo storage user) internal view returns (uint256 totalPending) {
        // Loop through each reward period from last updated period to the current
        for (uint256 i = user.lastUpdatedRewardPeriod; i < currentRewardPeriodIndex; i++) {
            uint256 pending = _calculatePending(user, i);
            totalPending += pending;
        }
    }

    /// @notice Checks if any future or ongoing reward period is currently active.
    /// @return A boolean indicating if any reward period is active.
    function _isRewardPeriodActive() internal view returns (bool) {
        if (currentRewardPeriodIndex == 0) {
            return false; // No reward periods have been set
        }
        RewardPeriod memory latestPeriod = rewardPeriods[currentRewardPeriodIndex - 1];
        // If the current time is within the latest period's end time, an active reward period exists
        return block.timestamp <= latestPeriod.endTime;
    }

    /// @notice Updates the validator state based on the current time.
    /// @dev This function should be called regularly to ensure accurate reward calculations.
    function _updateValidator() internal {
        if (block.timestamp <= lastRewardTime) return;

        if (totalStaked == 0) {
            lastRewardTime = block.timestamp;
            return;
        }

        // Only update the current active reward period
        RewardPeriod storage  currentPeriod = rewardPeriods[currentRewardPeriodIndex - 1];
        
        // Check if the current time is within the current reward period
        if (block.timestamp >= currentPeriod.startTime && block.timestamp <= currentPeriod.endTime) {
            uint256 lrdsReward = _calculateLrdsReward(currentRewardPeriodIndex - 1);
            currentPeriod.accTokenPerShare += (lrdsReward * PRECISION_FACTOR) / totalStaked;
        }

        lastRewardTime = block.timestamp;
    }

    /// @notice Updates the user's accumulated rewards across active reward periods.
    /// @param _user The user information struct to be updated.
    function _updateUserRewards(UserInfo storage _user) internal {
        uint256 accumulatedRewards = _user.rewardDebt;

        // Loop through each reward period from the user's last updated period to the current
        for (uint256 i = _user.lastUpdatedRewardPeriod; i < currentRewardPeriodIndex; i++) {
            RewardPeriod memory period = rewardPeriods[i];
            
            if (period.endTime <= block.timestamp) {
                accumulatedRewards += (_user.amount * period.accTokenPerShare) / PRECISION_FACTOR;
            }
        }

        _user.rewardDebt = accumulatedRewards;
    }

    /// @notice Calculates the LRDS reward for a given reward period index.
    /// @dev This function calculates the reward based on the elapsed time in the reward period and applies the multiplier.
    ///      The multiplier is derived from the time between the last reward time and the current block timestamp, 
    ///      relative to the reward period's duration.
    /// @param index The index of the reward period for which the reward should be calculated.
    /// @return The amount of LRDS reward for the specified period, considering the elapsed time and multiplier.
    function _calculateLrdsReward(uint256 index) internal view returns (uint256) {
        // Retrieve the details of the reward period at the given index
        RewardPeriod memory period = rewardPeriods[index];

        // Calculate the reward per second for the reward period
        uint256 rewardPerSecond = period.totalReward / (period.endTime - period.startTime);

        // Calculate the multiplier based on the elapsed time since the last reward time
        uint256 multiplier = _getMultiplier(lastRewardTime, block.timestamp, period.endTime);

        // Return the calculated reward, applying the multiplier to the reward per second
        return multiplier * rewardPerSecond;
    }

    /// @notice Calculates the multiplier for reward calculation based on the elapsed time in the reward period.
    /// @param start The start time of the reward calculation (e.g., lastRewardTime or period start).
    /// @param end The end time for the reward calculation (e.g., current block timestamp).
    /// @param periodEnd The end time of the reward period being calculated.
    /// @return The multiplier, representing the elapsed time within the period.
    function _getMultiplier(uint256 start, uint256 end, uint256 periodEnd) internal pure returns (uint256) {
        if (end <= start) return 0;
        // Ensures that the calculation does not exceed the reward period's end
        return (end < periodEnd ? end : periodEnd) - start;
    }

    /// @notice Calculates the pending rewards for a user in a specific reward period. 
    /// @param _user The UserInfo struct of the user.
    /// @param _periodIndex The index of the reward period to check.
    /// @return The amount of pending rewards for the user in this period.
    function _calculatePending(UserInfo storage _user, uint256 _periodIndex) internal view returns (uint256) {
        RewardPeriod memory period = rewardPeriods[_periodIndex];

        // If the user's staked amount is 0 or the current time is before the reward period start time, return 0 pending reward
        if (_user.amount == 0 || block.timestamp < period.startTime) {
            return 0;
        }

        // Calculate the current accTokenPerShare for this reward period
        uint256 currentAccTokenPerShare = period.accTokenPerShare;
        if (block.timestamp <= period.endTime) {
            uint256 lrdsReward = _calculateLrdsReward(_periodIndex);
            currentAccTokenPerShare += (lrdsReward * PRECISION_FACTOR) / totalStaked;
        }

        // Calculate the pending reward based on the user's staked amount and the period's accTokenPerShare
        uint256 pendingReward = (_user.amount * currentAccTokenPerShare) / PRECISION_FACTOR;

        // Subtract the user's reward debt to get the actual pending reward for this period
        return pendingReward - _user.rewardDebt;
    }

    /*//////////////////////////////////////////////////////////////
                               GOVERNANCE
    //////////////////////////////////////////////////////////////*/

    /// @notice Return the voting weight of a givne user
    /// @param _user The address of a user
    function veLrdsBalance(address _user) external view returns (uint256) {
         UserInfo storage user = userInfo[_user];

        // If user has no amount staked or if not the master validator, return 0
        if (user.amount == 0 || quality != 1) return 0;

        // Determine the effective lock end time
        uint256 effectiveLockEndTime = user.autoMax ? block.timestamp + MAX_LOCK : user.lockEndTime;

        // Ensure the lock period has not expired
        if (block.timestamp >= effectiveLockEndTime) return 0;

        // Calculate the duration remaining until the effective lock end time
        uint256 duration = effectiveLockEndTime - block.timestamp;

        // Calculate veLrds based on remaining lock duration
        uint256 veLrds = (user.amount * duration) / MAX_LOCK;

        return veLrds;
    }

    /*//////////////////////////////////////////////////////////////
                               OWNER
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IValidator
    function claimFees() external nonReentrant whenNotPaused onlyOwner {
        uint256 claimed = ValidatorFees(validatorFees).claimFeesFor(msg.sender);

        emit ClaimFees(msg.sender, claimed);
    }

    /// @notice Sets the deposit fee for the contract.
    /// @param _fee The new fee percentage to set.
    /// @dev Only the owner can call this function.
    function setDepositFee(uint256 _fee) external nonReentrant whenNotPaused onlyOwner {
        if (_fee < 0) revert WrongFee();
        if (_fee > DEPOSIT_MAX_FEE) revert FeeTooHigh();
        depositFee = _fee;

        emit SetDepositFee(msg.sender, _fee);
    }

    // @notice Sets the claim fee for the contract.
    /// @param _fee The new fee percentage to set.
    /// @dev Only the owner can call this function.
    function setClaimFee(uint256 _fee) external nonReentrant whenNotPaused onlyOwner {
        if (_fee < 0) revert WrongFee();
        if (_fee > CLAIM_MAX_FEE) revert FeeTooHigh();
        claimFee = _fee;

        emit SetClaimFee(msg.sender, _fee);
    }
    
    /*//////////////////////////////////////////////////////////////
                               ADMIN
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Sets a new name for the validator.
    /// @param _newName The new name to set.
    /// @dev Only the admin can call this function.
    function setName(string calldata _newName) external onlyAdmin {
        _name = _newName;
    }

    /**
     * @dev Sets the address of the verifier for signature verification.
     * @param _verifier The address of the verifier contract.
     */
    function setVerifier(address _verifier) external onlyAdmin {
        if (_verifier == address(0)) revert ZeroAddress();
        verifier = _verifier;
    }
    
    /// @notice Sets the address of the master validator.
    /// @dev This function allows the admin to set or update the master validator address.
    ///      The new address must be non-zero to ensure valid assignments.
    /// @param _validator The address of the new master validator.
    function setMasterValidator(address _validator) external onlyAdmin {
        // Ensure the provided address is not zero
        if (_validator == address(0)) revert ZeroAddress();
        
        // Set the master validator address
        masterValidator = _validator;
    }

    /// @notice Sets the address of the voter.
    /// @dev This function allows the admin to set or update the voter address.
    ///      The new address must be non-zero to ensure valid assignments.
    /// @param _voter The address of the new voter.
    function setVoter(address _voter) external onlyAdmin {
        // Ensure the provided address is not zero
        if (_voter == address(0)) revert ZeroAddress();
        
        // Set the voter address
        voter = _voter;
    }

    /*//////////////////////////////////////////////////////////////
                               FACTORY
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Sets the paused state of the contract.
    /// @dev This function allows the factory (only the factory can call it) to pause or unpause the contract.
    ///      Pausing the contract might prevent certain operations or changes from occurring, providing a safety mechanism.
    /// @param _state The new paused state: `true` to pause the contract, `false` to unpause it.
    function setPauseState(bool _state) external onlyFactory {
        // If the new state is the same as the current state, revert the transaction
        if (isPaused == _state) revert StateUnchanged();

        // Update the paused state based on the provided value
        isPaused = _state;
    }
}