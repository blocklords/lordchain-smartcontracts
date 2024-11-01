// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./interfaces/IValidatorFactory.sol";
import "./interfaces/IValidator.sol";
import "./ValidatorFees.sol";

/// @title Validator Contract
/// @notice This contract allows users to stake tokens, manage reward periods, and claim rewards.
/// @dev The contract uses ERC20 and includes reward management for staked tokens.

contract Validator is IValidator, ERC20Permit, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct RewardPeriod {
        uint256 startTime;
        uint256 endTime;
        address stakeToken;
        address rewardToken;
        uint256 totalReward;
    }

    struct UserInfo {
        uint256 amount; // How many staked tokens the user has provided
        uint256 lockStartTime; // lock start time.
        uint256 lockEndTime; // lock end time.
        uint256 rewardDebt; // Reward debt
        mapping(uint256 => uint256) accruedRewards; // Mapping to store accrued rewards for each period
    }

    string private _name;
    string private _type;
    address private _voter;

    uint256 public totalStaked;
    // Accrued token per share
    uint256 public accTokenPerShare;
    // The precision factor
    uint256 public PRECISION_FACTOR;
    uint256 public depositFee;
    uint256 public claimFee;
    uint256 public constant MAX_FEE = 1000; // 10%

    /// @inheritdoc IValidator
    address public token;
    /// @inheritdoc IValidator
    address public validatorFees;
    /// @inheritdoc IValidator
    address public factory;
    // The block number of the last validator update
    uint256 public lastRewardTime;

    address public admin;
    address public owner;
    uint256 public validatorId;

    uint256[] public validLockDurations;

    mapping(uint256 => RewardPeriod) public rewardPeriods;
    uint256 public currentRewardPeriodIndex;

    // Mapping to store allocated reward ratio for each period
    mapping(uint256 => uint256) public rewardPeriodAllocatedRatios;

    // Info of each user that stakes tokens (stakedToken)
    mapping(address => UserInfo) public userInfo;

    constructor() ERC20("", "") ERC20Permit("") {}

    /// @inheritdoc IValidator
    function initialize(
        address _admin,
        address _token,
        address _owner,
        uint256 _validatorId
    ) external nonReentrant {
        if (factory != address(0)) revert FactoryAlreadySet();
        factory = _msgSender();
        _voter = IValidatorFactory(factory).voter();
        (admin, token, owner, validatorId) = (_admin, _token, _owner, _validatorId);

        validatorFees = address(new ValidatorFees(token));

        string memory symbol = ERC20(_token).symbol();
        _name = string(abi.encodePacked("Stable AMM - ", symbol));

        depositFee = 100; // 1%
        claimFee = 500; // 5%
        PRECISION_FACTOR = 10 ** 12;

        validLockDurations.push(0);
        validLockDurations.push(10 minutes);
        validLockDurations.push(30 minutes);
        validLockDurations.push(1 hours);
        validLockDurations.push(4 hours);
        validLockDurations.push(1 days);
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
    ) external nonReentrant {
        if (msg.sender != admin) revert NotAdmin();

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
            RewardPeriod storage previousPeriod = rewardPeriods[currentRewardPeriodIndex - 1];
            if (_startTime != previousPeriod.endTime) revert StartTimeNotAsExpected();
        }

        rewardPeriods[currentRewardPeriodIndex++] = RewardPeriod({
            startTime: _startTime,
            endTime: _endTime,
            stakeToken: _stakeToken,
            rewardToken: _rewardToken,
            totalReward: _totalReward
        });

        rewardPeriodAllocatedRatios[currentRewardPeriodIndex - 1] = 1;
    }

    /// @inheritdoc IValidator
    function claimFees() external nonReentrant {
        if (msg.sender != owner) revert NotOwner();

        uint256 claimed = ValidatorFees(validatorFees).claimFeesFor(msg.sender);

        emit ClaimFees(msg.sender, claimed);
    }

    /// @inheritdoc IValidator
    function createLock(uint256 _amount, uint256 _lockDuration) external nonReentrant {
        if (!_isValidLockDuration(_lockDuration)) revert InvalidLockDuration();
        if (_amount == 0) revert ZeroAmount();
        if (_lockDuration == 0) revert ZeroDuration();
        if (!_isRewardPeriodActive()) revert RewardPeriodNotActive();

        UserInfo storage user = userInfo[msg.sender];
        if (user.amount > 0 || user.lockStartTime > 0) revert AllreadyLocked();

        _deposit(_amount, _lockDuration, user);
    }

    /// @inheritdoc IValidator
    function increaseAmount(uint256 _amount) external nonReentrant {
        if (_amount == 0) revert ZeroAmount();
        if (!_isRewardPeriodActive()) revert RewardPeriodNotActive();

        UserInfo storage user = userInfo[msg.sender];
        if (user.amount == 0) revert NoLockCreated();

        _deposit(_amount, 0, user);
    }

    /// @inheritdoc IValidator
    function extendDuration(uint256 _lockDuration) external nonReentrant {
        if (!_isValidLockDuration(_lockDuration)) revert InvalidLockDuration();
        if (_lockDuration == 0) revert ZeroDuration();
        if (!_isRewardPeriodActive()) revert RewardPeriodNotActive();

        UserInfo storage user = userInfo[msg.sender];
        if (user.amount == 0) revert NoLockCreated();

        _deposit(0, _lockDuration, user);
    }

    /// @inheritdoc IValidator
    function withdraw() external nonReentrant {
        UserInfo storage user = userInfo[msg.sender];

        if (user.amount == 0) revert ZeroAmount();
        if (block.timestamp < user.lockEndTime) revert TimeNotUp();

        _updateValidator();

        if (IERC20(rewardPeriods[currentRewardPeriodIndex - 1].stakeToken).balanceOf(address(this)) < user.amount) revert NotEnoughStakeToken();

        uint256 totalPending = 0;
        for (uint256 i = 0; i < currentRewardPeriodIndex; i++) {
            uint256 pending = _calculatePending(user, i);
            totalPending += pending;
            user.accruedRewards[i] += pending;
        }

        (uint256 userClaimAmount, uint256 feeAmount) = _claim(totalPending);

        IERC20(rewardPeriods[currentRewardPeriodIndex - 1].stakeToken).safeTransfer(address(msg.sender), user.amount);

        totalStaked -= user.amount;
        delete userInfo[msg.sender];

        emit Withdraw(msg.sender, user.amount, userClaimAmount, feeAmount);
    }

    /// @inheritdoc IValidator
    function claim() external nonReentrant {
        if (!_isRewardPeriodActive()) revert RewardPeriodNotActive();

        UserInfo storage user = userInfo[msg.sender];

        if (user.amount == 0) revert NoStakeFound();

        _updateValidator();

        uint256 totalPending = 0;
        for (uint256 i = 0; i < currentRewardPeriodIndex; i++) {
            uint256 pending = _calculatePending(user, i);
            totalPending += pending;
            user.accruedRewards[i] += pending;
        }

        (uint256 userClaimAmount, uint256 feeAmount) = _claim(totalPending);

        user.rewardDebt = (user.amount * accTokenPerShare) / PRECISION_FACTOR;

        emit Claim(msg.sender, userClaimAmount, feeAmount);
    }

    /// @notice Sets the deposit or claim fee for the contract.
    /// @param _isDepositFee A boolean indicating whether to set the deposit fee (true) or claim fee (false).
    /// @param _fee The new fee percentage to set.
    /// @dev Only the owner can call this function.
    function setFee(bool _isDepositFee, uint256 _fee) external nonReentrant {
        if (msg.sender != owner) revert NotOwner();
        if (_fee > MAX_FEE) revert FeeTooHigh();
        if (_fee == 0) revert ZeroFee();
        if (_isDepositFee) {
            depositFee = _fee;
        } else {
            claimFee = _fee;
        }
    }

    /// @notice Adds a new valid lock duration.
    /// @param _duration The duration to add to valid lock durations.
    /// @dev Only the admin can call this function.
    function addLockDuration(uint256 _duration) external nonReentrant {
        if (msg.sender != admin) revert NotAdmin();
        validLockDurations.push(_duration);
    }

    /// @notice Updates an existing lock duration.
    /// @param _index The index of the lock duration to update.
    /// @param _newDuration The new duration to set.
    /// @dev Only the admin can call this function.
    function updateLockDuration(
        uint256 _index,
        uint256 _newDuration
    ) external nonReentrant {
        if (msg.sender != admin) revert NotAdmin();
        if (_index >= validLockDurations.length) revert InvalidLockDuration();
        validLockDurations[_index] = _newDuration;
    }

    /// @notice Removes a lock duration from valid options.
    /// @param _index The index of the lock duration to remove.
    /// @dev Only the admin can call this function.
    function removeLockDuration(uint256 _index) external nonReentrant {
        if (msg.sender != admin) revert NotAdmin();
        if (_index >= validLockDurations.length) revert InvalidLockDuration();

        validLockDurations[_index] = validLockDurations[validLockDurations.length - 1];
        validLockDurations.pop();
    }

    /// @notice Gets the pending rewards for a user.
    /// @param _userAddress The address of the user to query.
    /// @return The amount of pending rewards for the user.
    function getUserPendingReward(address _userAddress) external view returns (uint256) {
        UserInfo storage user = userInfo[_userAddress];
        uint256 totalPending = 0;

        if (block.timestamp > lastRewardTime && totalStaked > 0) {
            for (uint256 i = 0; i < currentRewardPeriodIndex; i++) {
                uint256 lrdsReward = calculateLrdsReward(i);
                uint256 adjustedTokenPerShare = accTokenPerShare + (lrdsReward * PRECISION_FACTOR) / totalStaked;
                totalPending += (user.amount * adjustedTokenPerShare) / PRECISION_FACTOR - user.rewardDebt;
            }
        } else {
            return (user.amount * accTokenPerShare) / PRECISION_FACTOR - user.rewardDebt;
        }

        return totalPending;
    }

    function _deposit(
        uint256 _amount,
        uint256 _lockDuration,
        UserInfo storage _user
    ) internal {
        _updateValidator();

        if (_amount > 0) {
            uint256 fee = (_amount * depositFee) / 10000; //  depositFee (5 = 0.05%)
            uint256 amountAfterFee = _amount - fee;

            if (amountAfterFee <= 0) revert InsufficientAmount();

            // Transfer the staked amount to the contract
            IERC20(rewardPeriods[currentRewardPeriodIndex - 1].stakeToken).safeTransferFrom(msg.sender, address(this), amountAfterFee);

            if (fee > 0) {
                IERC20(rewardPeriods[currentRewardPeriodIndex - 1].stakeToken).safeTransferFrom(msg.sender, validatorFees, fee); // transfer to ValidatorFees address
            }

            _user.amount += amountAfterFee;
            totalStaked += amountAfterFee;

            if (_lockDuration > 0) {
                _user.lockStartTime = block.timestamp;
                _user.lockEndTime = _lockDuration + block.timestamp;
            }
        }

        if (_lockDuration > 0 && _amount == 0) {
            _user.lockEndTime += _lockDuration;
        }

        _user.rewardDebt = (_user.amount * accTokenPerShare) / PRECISION_FACTOR;

        emit Deposit(msg.sender, _amount, _lockDuration, _user.lockEndTime);
    }

    function _claim(uint256 pending) internal returns (uint256 userClaimAmount, uint256 feeAmount) {
        if (pending == 0) return (0, 0);

        if (IERC20(rewardPeriods[currentRewardPeriodIndex - 1].rewardToken).balanceOf(address(this)) < pending) revert NotEnoughRewardToken();

        feeAmount = (pending * claimFee) / 10000; // claimFee (30 = 0.3%)
        userClaimAmount = pending - feeAmount;

        IERC20(rewardPeriods[currentRewardPeriodIndex - 1].rewardToken).safeTransfer(owner, feeAmount);

        IERC20(rewardPeriods[currentRewardPeriodIndex - 1].rewardToken).safeTransfer(msg.sender, userClaimAmount);
    }

    /// @notice Checks if a lock duration is valid.
    /// @param _lockDuration The duration to check.
    /// @return A boolean indicating whether the duration is valid.
    function _isValidLockDuration(uint256 _lockDuration) internal view returns (bool) {
        for (uint256 i = 0; i < validLockDurations.length; i++) {
            if (validLockDurations[i] == _lockDuration) {
                return true;
            }
        }
        return false;
    }

    /// @notice Checks if any reward period is currently active.
    /// @return A boolean indicating if any reward period is active.
    function _isRewardPeriodActive() internal view returns (bool) {
        for (uint256 i = 0; i < currentRewardPeriodIndex; i++) {
            RewardPeriod storage period = rewardPeriods[i];
            if (
                block.timestamp >= period.startTime &&
                block.timestamp <= period.endTime
            ) {
                return true;
            }
        }
        return false;
    }

    /// @notice Updates the validator state based on the current time.
    /// @dev This function should be called regularly to ensure accurate reward calculations.
    function _updateValidator() internal {
        if (block.timestamp <= lastRewardTime) return;

        if (totalStaked == 0) {
            lastRewardTime = block.timestamp;
            return;
        }

        for (uint256 i = 0; i < currentRewardPeriodIndex; i++) {
            uint256 lrdsReward = calculateLrdsReward(i);
            accTokenPerShare = accTokenPerShare + (lrdsReward * PRECISION_FACTOR) / totalStaked;
        }

        lastRewardTime = block.timestamp;
    }

    function calculateLrdsReward(uint256 index) private view returns (uint256) {
        RewardPeriod storage period = rewardPeriods[index];

        uint256 rewardPerSecond = period.totalReward / (period.endTime - period.startTime);
        uint256 multiplier = _getMultiplier(lastRewardTime, block.timestamp, period.endTime);

        return multiplier * rewardPerSecond;
    }

    /// @notice Calculates the multiplier based on the given time frames.
    /// @param _from The starting timestamp.
    /// @param _to The ending timestamp.
    /// @param _endTime The ending time of the reward period.
    /// @return The calculated multiplier for the reward.
    function _getMultiplier(uint256 _from, uint256 _to, uint256 _endTime) internal pure returns (uint256) {
        if (_to <= _endTime) {
            return _to - _from;
        } else if (_from >= _endTime) {
            return 0;
        } else {
            return _endTime - _from;
        }
    }

    /// @notice Calculates the pending rewards for a user in a specific reward period.
    /// @param _user The UserInfo struct of the user.
    /// @param _periodIndex The index of the reward period to check.
    /// @return The amount of pending rewards for the user in this period.
    function _calculatePending(UserInfo storage _user, uint256 _periodIndex) internal view returns (uint256) {
        RewardPeriod storage period = rewardPeriods[_periodIndex];
        if (_user.amount == 0 || block.timestamp < period.startTime) {
            return 0;
        }

        return (_user.amount * accTokenPerShare) / PRECISION_FACTOR - _user.rewardDebt;

        // uint256 endTimeToConsider = block.timestamp > period.endTime
        //     ? period.endTime
        //     : block.timestamp;

        // uint256 timeBasedRatio = (endTimeToConsider - period.startTime) /
        //     (period.endTime - period.startTime);

        // uint256 userRewardRatio = (_user.amount *
        //     rewardPeriodAllocatedRatios[_periodIndex] *
        //     timeBasedRatio) / totalStaked;
        // return userRewardRatio - _user.accruedRewards[_periodIndex];
    }
}
