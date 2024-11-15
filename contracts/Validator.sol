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
        uint256 totalReward;        // The total reward amount for this period
        uint256 accTokenPerShare;   // The accumulated tokens per share for this reward period
        uint256 lastRewardTime;     // The last time rewards were distributed
        bool isActive;
    }

    // UserInfo struct is used to store staking information for each user
    struct UserInfo {
        uint256 amount;                  // The amount of tokens the user has staked
        uint256 lockStartTime;           // The start time of the staking lock period
        uint256 lockEndTime;             // The end time of the staking lock period
        uint256 rewardDebt;              // The reward debt, used to calculate the user's reward share
        uint256 lastUpdatedRewardPeriod; // The index of the last reward period in which rewards were calculated for the user
        bool autoMax;                    // Indicates whether the user has enabled automatic maximum staking
    }

    struct BoostInfo {
        uint256 boostRewardDebt;         // The boost reward debt, used to calculate the user's boost reward share
        uint256 lastClaimedBoostIndex;   // The index of the last boost reward period in which rewards were calculated for the user
    }

    struct BoostReward {
        uint256 startTime;         // The start time of the reward period
        uint256 endTime;           // The end time of the reward period
        uint256 totalReward;       // The total reward amount for this period
        uint256 claimedAmount;     // The total amount of reward claimed so far
        uint256 accTokenPerShare;  // Accumulated reward per share for calculating user entitlements
        uint256 lastUpdatedTime;   // The last update timestamp for this boost period
    }

    uint256 public constant DEPOSIT_MAX_FEE = 100;          // The maximum deposit fee (1%)
    uint256 public constant CLAIM_MAX_FEE = 500;            // The maximum claim fee (5%)
    uint256 public constant WEEK = 7 days;                  // One week in seconds
    // uint256 public constant MAX_LOCK = (209 * WEEK) - 1; // Maximum lock duration (209 weeks - 1 second) --> main
    // uint256 public constant MIN_LOCK = WEEK;             // Minimum lock duration (520 seconds) --> main
    uint256 public constant MAX_LOCK = 14560;               // Maximum lock duration (14560 seconds) -->test
    uint256 public constant MIN_LOCK = 520;                 // Minimum lock duration (520 seconds) --> test
    uint256 public constant MULTIPLIER = 10**18;            // The precision factor for reward calculations

    bool public isClaimed;                                  // Flag to indicate whether the validator has been claimed
    bool public isPaused;                                   // Flag to indicate whether the contract is paused

    string public _name;                                    // The name of the validator contract

    uint256 public totalStaked;                             // The total amount of staked tokens
    uint256 public PRECISION_FACTOR;                        // The precision factor for reward calculations
    uint256 public depositFee;                              // The deposit fee percentage
    uint256 public claimFee;                                // The claim fee percentage
    uint256 public validatorId;                             // The unique identifier of the validator
    uint256 public currentRewardPeriodIndex;                // The current reward period index
    uint256 public quality;                                 // The quality level of the validator (e.g., Master, Super, etc.)
    uint256 public currentBoostRewardPeriodIndex;           // The index of the current active boost reward period

    address public token;                                   // The address of LRDS
    /// @inheritdoc IValidator
    address public validatorFees;                           // The address of the validator fees contract
    /// @inheritdoc IValidator
    address public factory;                                 // The address of the PoolFactory that created this contract
    // address private voter;                               // The address of the voter (for validation purposes)
    address private governance;                             // The address of the governance (for validation purposes)
    address public admin;                                   // The address of the contract admin
    address public owner;                                   // The address of the contract owner
    address public verifier;                                // The address of the verifier for signature verification
    address public masterValidator;                         // The address of the master validator contract

    // Mapping to store reward periods
    mapping(uint256 => RewardPeriod) public rewardPeriods;
    // Mapping to store boost reward periods
    mapping(uint256 => BoostReward) public boostRewards;
    // Mapping to store information about each user who stakes tokens
    mapping(address => UserInfo) public userInfo;

    mapping(address => BoostInfo) public boostInfo;
    // Mapping to store the count of nodes based on their quality
    mapping(uint256 => uint256) public nodeCounts;

    // Modifier to ensure only the admin can access the function
    modifier onlyAdmin() {
        if (msg.sender != address(admin)) revert NotAdmin();
        _;
    }

    // Modifier to ensure only the owner can access the function
    modifier onlyOwner() {
        if (msg.sender != address(owner)) revert NotOwner();
        _;
    }

    // Modifier to ensure the contract is not paused
    modifier whenNotPaused() {
        if (isPaused) revert ContractPaused();
        _;
    }

    // Modifier to ensure only the factory can access the function
    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    constructor() {}

    /// @inheritdoc IValidator
    function initialize(
        address _token,
        address _admin,
        address _owner,
        uint256 _validatorId,
        uint256 _quality,
        address _verifier
    ) external nonReentrant {
        if (factory != address(0)) revert FactoryAlreadySet();
        token = _token;
        factory = msg.sender;
        // voter = IValidatorFactory(factory).voter();
        (admin, owner, validatorId, quality) = (_admin, _owner, _validatorId, _quality);
        if (_quality < 1 || _quality > 7) revert QualityWrong();
        PRECISION_FACTOR = 10 ** 12;

        validatorFees = address(new ValidatorFees(token));

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
    /// @param _totalReward The total amount of reward tokens available for this period.
    /// @dev This function can only be called by the admin.
    function setRewardPeriod(
        uint256 _startTime,
        uint256 _endTime,
        uint256 _totalReward
    ) external nonReentrant onlyAdmin {

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
            if (_startTime <= previousPeriod.endTime) revert StartTimeNotAsExpected();
        }

        rewardPeriods[currentRewardPeriodIndex++] = RewardPeriod({
            startTime: _startTime,
            endTime: _endTime,
            totalReward: _totalReward,
            accTokenPerShare: 0,
            lastRewardTime: _startTime,
            isActive: true
        });
        
        IValidatorFactory(factory).addTotalValidators(_startTime, _endTime, _totalReward);
    }

    /*//////////////////////////////////////////////////////////////
                               VALIDATOR
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IValidator
    function createLock(uint256 _amount, uint256 _lockDuration) external nonReentrant whenNotPaused {
        if (_amount == 0) revert ZeroAmount();
        if (_lockDuration == 0 || _lockDuration < MIN_LOCK || _lockDuration > MAX_LOCK) revert WrongDuration();

        UserInfo storage user = userInfo[msg.sender];
        if (user.amount > 0 || user.lockStartTime > 0) revert AllreadyLocked();

        IValidatorFactory(factory).addTotalStakedWallet();

        _deposit(_amount, _lockDuration, user);
    }

    /// @inheritdoc IValidator
    function increaseAmount(uint256 _amount) external nonReentrant whenNotPaused {
        if (_amount == 0) revert ZeroAmount();

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
        
        // Reset votes associated with the user
        if (block.timestamp > user.lockEndTime) {
            IGovernance(governance).resetVotes(msg.sender);
        }

        _deposit(0, _lockDuration, user);
    }

    /// @inheritdoc IValidator
    function claim() external nonReentrant whenNotPaused {
        UserInfo storage user = userInfo[msg.sender];

        if (user.amount == 0) revert NoStakeFound();

        // Update global reward state and user-specific rewards
        _updateValidator();
        // _updateUserRewards(user);
        // _updateBoostReward(currentBoostRewardPeriodIndex);

        uint256 currentPeriod = getCurrentPeriod();

        // Calculate the total pending rewards
        uint256 totalPending = _calculateTotalPending(user);

        if (totalPending <= 0) revert NoReward();

        // Call _claim to distribute the rewards
        _claim(totalPending);

        user.rewardDebt = (user.amount * rewardPeriods[currentPeriod].accTokenPerShare) / PRECISION_FACTOR;

        // Update the user's last updated reward period
        user.lastUpdatedRewardPeriod = rewardPeriods[currentPeriod].isActive ? currentPeriod : (currentPeriod + 1 < currentRewardPeriodIndex ? currentPeriod + 1 : currentPeriod);

    }

    /// @inheritdoc IValidator
    function withdraw() external nonReentrant whenNotPaused {
        UserInfo storage user = userInfo[msg.sender];

        if (user.amount <= 0) revert ZeroAmount();
        if (block.timestamp < user.lockEndTime) revert TimeNotUp();
        if (user.autoMax == true) revert AutoMaxTime();

        // Update global reward state and user-specific rewards
        _updateValidator();
        // _updateUserRewards(user);
        // _updateBoostReward(currentBoostRewardPeriodIndex);

        if (IERC20(token).balanceOf(address(this)) < user.amount) revert NotEnoughRewardToken();

        // Calculate the total pending rewards
        uint256 totalPending = _calculateTotalPending(user);

        if (totalPending > 0) {
            // Call _claim to distribute the rewards
            _claim(totalPending);
        }

         // Transfer the user's staked amount back to them
        IERC20(token).safeTransfer(msg.sender, user.amount);

        uint256 currentPeriod = getCurrentPeriod();

        user.rewardDebt = (user.amount * rewardPeriods[currentPeriod].accTokenPerShare) / PRECISION_FACTOR;

        // Reset votes associated with the user
        IGovernance(governance).resetVotes(msg.sender);

        // Update the global staking total
        totalStaked -= user.amount;

        // Update the total staked amount and wallet count in the factory contract
        IValidatorFactory(factory).subTotalStakedAmount(user.amount);
        IValidatorFactory(factory).subTotalStakedWallet();

        // reset the user's information from the contract
        user.amount        = 0;
        user.lockStartTime = 0;
        user.lockEndTime   = 0;
        user.autoMax       = false;
        user.lastUpdatedRewardPeriod = rewardPeriods[currentPeriod].isActive ? currentPeriod : (currentPeriod + 1 < currentRewardPeriodIndex ? currentPeriod + 1 : currentPeriod);


        emit Withdraw(msg.sender, user.amount);
    }
    
    /// @inheritdoc IValidator
    function setAutoMax(bool _bool) external nonReentrant whenNotPaused {
        UserInfo storage user = userInfo[msg.sender];
        if (user.amount  == 0) revert NoLockCreated();
        if (user.autoMax == _bool) revert TheSameValue();
        user.autoMax     = _bool;
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
        if (amount < requiredAmount * MULTIPLIER) revert InsufficientAmount();

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

    // /// @notice Gets the pending rewards for a user.
    // /// @param _userAddress The address of the user to query.
    // /// @return The amount of pending rewards for the user.
    function getUserPendingReward(address _userAddress) external view returns (uint256) {
        UserInfo storage user = userInfo[_userAddress];
        // return _calculateTotalPending(user);
        uint256 totalPending = 0;

        for (uint256 i = user.lastUpdatedRewardPeriod; i < currentRewardPeriodIndex; i++) {
            RewardPeriod memory period = rewardPeriods[i];

            if (user.amount == 0 || block.timestamp < period.startTime) {
                continue;
            }

            uint256 rewardDebt = 0;
            if(user.lastUpdatedRewardPeriod == i) {
                rewardDebt = user.rewardDebt;
            }
            
            uint256 multiplier = _getMultiplier(period.lastRewardTime, block.timestamp, period.endTime);
            uint256 rewardPerSecond = period.totalReward / (period.endTime - period.startTime);
            
            uint256 lrdsReward = multiplier * rewardPerSecond;
            uint256 accTokenPerShare = period.accTokenPerShare + (lrdsReward * PRECISION_FACTOR) / totalStaked;
            uint256 pending = (user.amount * accTokenPerShare) / PRECISION_FACTOR - rewardDebt;

            totalPending += pending;
        }

        return totalPending;
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
        if (quality == 1) {
            UserInfo storage info = userInfo[_userAddress];
            return (info.amount, info.autoMax);
        } else {
            (uint256 amount, bool isAutoMax) = IValidator(masterValidator).getAmountAndAutoMax(_userAddress);
            return (amount, isAutoMax);
        }
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
        // _updateUserRewards(_user);
        // _updateBoostReward(currentBoostRewardPeriodIndex);

        uint256 currentPeriod = getCurrentPeriod();

        if (_amount > 0) {
            // Calculate the deposit fee (depositFee is in basis points, e.g., 500 = 5%)
            uint256 fee = (_amount * depositFee) / 10000;
            uint256 amountAfterFee = _amount - fee;

            // Ensure the amount after fee is positive
            if (amountAfterFee <= 0) revert InsufficientAmount();

            if (_user.amount > 0) {
                // uint256 pending = (_user.amount *  rewardPeriods[currentPeriod].accTokenPerShare) / PRECISION_FACTOR - _user.rewardDebt;
                uint256 totalPending = _calculateTotalPending(_user);
                if (totalPending > 0) {
                    // Call _claim to distribute the rewards
                    _claim(totalPending);
                }
            }
            
            // Transfer the staked amount to the contract
            IERC20(token).safeTransferFrom(msg.sender, address(this), amountAfterFee);

            // If there is a fee, transfer it to the validatorFees address
            if (fee > 0) {
                IERC20(token).safeTransferFrom(msg.sender, validatorFees, fee);
            }

            // Update the user's staked amount
            _user.amount += amountAfterFee;
            totalStaked  += amountAfterFee;

            _user.lastUpdatedRewardPeriod = rewardPeriods[currentPeriod].isActive ? currentPeriod : (currentPeriod + 1 < currentRewardPeriodIndex ? currentPeriod + 1 : currentPeriod);

            _user.rewardDebt = (_user.amount * rewardPeriods[currentPeriod].accTokenPerShare) / PRECISION_FACTOR;

            // If a lock duration is provided, set the lock start and end times
            if (_lockDuration > 0) {
                _user.lockStartTime = block.timestamp;
                _user.lockEndTime = _lockDuration + block.timestamp;
            }

            // Update the total staked amount in the factory contract
            IValidatorFactory(factory).addTotalStakedAmount(amountAfterFee);
        }

        // If lock duration is provided but no amount is being deposited, just extend the lock duration
        if (_lockDuration > 0 && _amount == 0) {
            _user.lockEndTime = block.timestamp < _user.lockEndTime ? _user.lockEndTime + _lockDuration : block.timestamp + _lockDuration;
        }

        // Emit the Deposit event
        emit Deposit(msg.sender, _amount, _lockDuration, _user.lockEndTime);
    }

    /// @notice Returns the index of the current active reward period based on the current time.
    /// @dev This function checks which reward period is currently active based on the block timestamp.
    function getCurrentPeriod() internal view returns(uint256) {
        // If there are no reward periods, return 0
        if (currentRewardPeriodIndex == 0) {
            return 0;
        }
        
        // Loop through all reward periods and check if the current time is within any of them
        for (uint256 i = 0; i < currentRewardPeriodIndex; i++) {
            RewardPeriod storage period = rewardPeriods[i];
            
            // If the current time is within the reward period's valid range (startTime to endTime)
            if (block.timestamp >= period.startTime && block.timestamp <= period.endTime) {
                return i; // Return the index of the active period
            }
        }

        // If no active reward period is found and the current time is within a gap, return the last active period
        for (int256 i = int256(currentRewardPeriodIndex) - 1; i >= 0; i--) {
            RewardPeriod storage period = rewardPeriods[uint256(i)];
            if (block.timestamp >= period.startTime) {
                return uint256(i);  // Return the last active period before the gap
            }
        }

        // If no active reward period is found, return the index of the latest reward period
        return 0;
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
        if (IERC20(token).balanceOf(address(this)) < _pending) revert NotEnoughRewardToken();

        // Calculate the claim fee (claimFee is in basis points, e.g., 300 = 3%)
        feeAmount = (_pending * claimFee) / 10000;
        userClaimAmount = _pending - feeAmount;

        // Transfer the fee to the contract owner
        if (feeAmount > 0) {
            IERC20(token).safeTransfer(owner, feeAmount);
        }

        // Transfer the remaining rewards to the user
        IERC20(token).safeTransfer(msg.sender, userClaimAmount);
        
        emit Claim(msg.sender, userClaimAmount, feeAmount);
    }

    // /// @notice Calculates the total pending rewards for a user across all eligible reward periods.
    // /// @param _user The UserInfo struct of the user.
    // /// @return totalPending The total amount of pending rewards for the user.
    function _calculateTotalPending(UserInfo storage _user) internal view returns (uint256) {
        uint totalPending = 0;

        // Loop through each reward period from last updated period to the current
        for (uint256 i = _user.lastUpdatedRewardPeriod; i < currentRewardPeriodIndex; i++) {
            RewardPeriod memory period = rewardPeriods[i];

            if (_user.amount == 0 || block.timestamp < period.startTime) {
                continue;
            }

            uint256 rewardDebt = 0;
            if(_user.lastUpdatedRewardPeriod == i) {
                rewardDebt = _user.rewardDebt;
            }
            uint256 pending = (_user.amount *  period.accTokenPerShare) / PRECISION_FACTOR - rewardDebt;

            totalPending += pending;
        }

        return totalPending;
    }

    /// @notice Updates the validator state based on the current time.
    /// @dev This function should be called regularly to ensure accurate reward calculations.
    function _updateValidator() internal{

        // Loop through all reward periods to update rewards for the active periods
        for (uint256 i = 0; i < currentRewardPeriodIndex; i++) {
            RewardPeriod storage period = rewardPeriods[i];

            // Check if the current time is within the valid time range of the reward period
            if (block.timestamp >= period.startTime) {
                // If the current time is earlier than the last reward update time, skip this period
                if (block.timestamp <= period.lastRewardTime) {
                    continue;
                }

                // Calculate the reward for the current period and update the accumulated rewards per share
                if (period.isActive == true) {
                    
                    if (totalStaked > 0) {
                        uint256 lrdsReward = _calculateLrdsReward(i);
                        period.accTokenPerShare += (lrdsReward * PRECISION_FACTOR) / totalStaked;
                    }
                    
                    if (block.timestamp >= period.endTime) {
                        period.isActive = false;
                        period.lastRewardTime = period.endTime;
                    } else {
                        period.lastRewardTime = block.timestamp;
                    }
                }
            }
        }
    }

    // /// @notice Updates the user's accumulated rewards across active reward periods.
    // /// @param _user The user information struct to be updated.
    // function _updateUserRewards(UserInfo storage _user) internal {
    //     uint256 accumulatedRewards = _user.rewardDebt;

    //     // Loop through each reward period from the user's last updated period to the current
    //     for (uint256 i = _user.lastUpdatedRewardPeriod; i < currentRewardPeriodIndex; i++) {
    //         RewardPeriod memory period = rewardPeriods[i];
            
    //         if (period.endTime <= block.timestamp) {
    //             accumulatedRewards += (_user.amount * period.accTokenPerShare) / PRECISION_FACTOR;
    //         }
    //     }

    //     _user.rewardDebt = accumulatedRewards;
    // }

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
        uint256 multiplier = _getMultiplier(period.lastRewardTime, block.timestamp, period.endTime);

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

    /// @inheritdoc IValidator
    function stakeFor(address _user, uint256 _amount) external onlyGovernance {
        // Increase the user's staked amount
        UserInfo storage use = userInfo[_user];
        if (use.amount <= 0 ) revert NoLockCreated(); 
        use.amount += _amount;

        emit StakeForUser(_user, _amount);
    }

    /**
     * @dev Adds a new boost reward period.
     * @param _startTime The start time of the boost reward period.
     * @param _endTime The end time of the boost reward period.
     * @param _totalReward The total reward allocated for this boost period.
     */
    function addBoostReward(uint256 _startTime, uint256 _endTime, uint256 _totalReward) external onlyGovernance {

        boostRewards[currentBoostRewardPeriodIndex++] = BoostReward({
            startTime: _startTime,
            endTime: _endTime,
            totalReward: _totalReward,
            claimedAmount: 0,
            accTokenPerShare: 0,
            lastUpdatedTime: 0
        });

        emit BoostRewardAdded(_startTime, _endTime, _totalReward);
    }

     /**
     * @dev Allows users to claim accumulated boost rewards.
     * Claims all pending rewards from all unclaimed boost periods and transfers them to the user.
     * The function updates the claimed amount within each boost period and adjusts the user's reward debt.
     */
    function claimBoostReward() external nonReentrant whenNotPaused {
        UserInfo storage user = userInfo[msg.sender];
        BoostInfo storage userBoost = boostInfo[msg.sender];

        uint256 totalPending = 0;
        // Iterate through all unclaimed boost reward periods
        for (uint256 i = userBoost.lastClaimedBoostIndex; i < currentBoostRewardPeriodIndex; i++) {
            uint256 pending = _calculateBoostPending(user, i);

            // Get the remaining claimable amount for the boost reward period
            BoostReward storage boost = boostRewards[i];
            uint256 remainingReward = boost.totalReward - boost.claimedAmount;

            // Ensure there is enough reward available to claim
            if (pending > remainingReward) revert NotEnoughRewardToken();
            totalPending += pending;
            boost.claimedAmount += pending;  // Update the claimed amount for the boost period
        }

        if (totalPending <= 0) revert InvalidBoostReward();

        // Transfer the total pending boost reward to the user
        IERC20(token).transfer(msg.sender, totalPending);

        // Update the user's boostRewardDebt and lastClaimedBoostIndex
        userBoost.boostRewardDebt = (user.amount * boostRewards[currentBoostRewardPeriodIndex - 1].accTokenPerShare) / PRECISION_FACTOR;
        userBoost.lastClaimedBoostIndex = currentBoostRewardPeriodIndex - 1;

        emit BoostRewardClaimed(msg.sender, totalPending);
    }

     /**
     * @dev Calculates the pending boost reward for a user in a specified boost period.
     * @param _user The user's information.
     * @param _boostIndex The index of the boost period for which to calculate pending rewards.
     * @return The pending reward amount for the user in the specified boost period.
     */
    function _calculateBoostPending(UserInfo storage _user, uint256 _boostIndex) internal view returns (uint256) {
        BoostReward memory boost = boostRewards[_boostIndex];
        BoostInfo memory userBoost = boostInfo[msg.sender];

        // If the user's staked amount is 0 or the current time is before the reward period start time, return 0 pending reward
        if (_user.amount == 0 || block.timestamp < boost.startTime) {
            return 0;
        }

        // Calculate pending rewards directly using the updated accTokenPerShare
        uint256 pendingReward = (_user.amount * boost.accTokenPerShare) / PRECISION_FACTOR;

        // Subtract the user's boostRewardDebt to get the actual pending reward for the period
        return pendingReward - userBoost.boostRewardDebt;
    }

    /**
     * @dev Updates the boost reward state for a specific boost period.
     * Calculates and updates the accumulated rewards (accTokenPerShare) since the last update.
     * @param _boostIndex The index of the boost period to update.
     */
    function _updateBoostReward(uint256 _boostIndex) internal {
        BoostReward storage boost = boostRewards[_boostIndex];

        // Check if the boost period is active; return if it is not active or if no rewards are available
        if (block.timestamp < boost.startTime || block.timestamp > boost.endTime || boost.totalReward == 0) {
            return;
        }

        // Ensure the boost period has a valid time range and total reward greater than 0
        if (block.timestamp > boost.startTime && boost.totalReward > 0) {
            // Calculate reward per second
            uint256 rewardPerSecond = boost.totalReward / (boost.endTime - boost.startTime);

            // Use boost.lastUpdatedTime as the starting point for the multiplier
            uint256 multiplier = _getMultiplier(boost.lastUpdatedTime, block.timestamp, boost.endTime);

            // Update accTokenPerShare with the accumulated rewards
            uint256 boostReward = multiplier * rewardPerSecond;
            boost.accTokenPerShare += (boostReward * PRECISION_FACTOR) / totalStaked;

            // Update lastUpdatedTime to the current timestamp
            boost.lastUpdatedTime = block.timestamp;
        }
    }

    /**
     * @dev Retrieves the total pending boost reward for a user across all unclaimed boost periods.
     * @param userAddress The address of the user.
     * @return The total pending boost reward for the specified user.
     */
    function getBoostReward(address userAddress) external view returns (uint256) {
        UserInfo storage user = userInfo[userAddress];
        BoostInfo memory userBoost = boostInfo[msg.sender];
        uint256 totalPending = 0;

        // Iterate through all unclaimed boost reward periods
        for (uint256 i = userBoost.lastClaimedBoostIndex; i < currentBoostRewardPeriodIndex; i++) {
            totalPending += _calculateBoostPending(user, i);
        }

        return totalPending;
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

    /// @notice Sets the address of the governance.
    /// @dev This function allows the admin to set or update the governance address.
    ///      The new address must be non-zero to ensure valid assignments.
    /// @param _governance The address of the new governance.
    function setGovernance(address _governance) external onlyAdmin {
        // Ensure the provided address is not zero
        if (_governance == address(0)) revert ZeroAddress();
        
        // Set the governance address
        governance = _governance;
    }

    /**
    * @dev Allows the contract admin to pause or unpause the contract.
    * Only the admin can call this function to change the contract's paused status.
    * If the contract is already in the desired state, it will revert with `TheSameValue` error.
    *
    * @param _paused A boolean value indicating whether to pause (true) or unpause (false) the contract.
    */
    function setPause(bool _paused) external onlyOwner {
        // If the new paused status is the same as the current one, revert the transaction
        if (_paused == isPaused) revert TheSameValue();

        // Update the paused status to the new value
        isPaused = _paused;
    }
}