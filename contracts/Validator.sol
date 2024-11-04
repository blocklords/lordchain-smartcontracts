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

contract Validator is IValidator, ReentrancyGuard {
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
        // mapping(uint256 => uint256) accruedRewards; // Mapping to store accrued rewards for each period
    }

    bool public isClaimed;

    string private _name;
    string private _type;

    uint256 public lastRewardTime;
    uint256 public totalStaked;
    // Accrued token per share
    uint256 public accTokenPerShare;
    // The precision factor
    uint256 public PRECISION_FACTOR;
    uint256 public depositFee;
    uint256 public claimFee;
    uint256 public constant MAX_FEE = 1000; // 10%
    uint256 public validatorId;
    uint256 public currentRewardPeriodIndex;
    uint256[] public validLockDurations;

    /// @inheritdoc IValidator
    address public token;
    /// @inheritdoc IValidator
    address public validatorFees;
    /// @inheritdoc IValidator
    address public factory;
    // The block number of the last validator update
    address private _voter;
    address public admin;
    address public owner;


    mapping(uint256 => RewardPeriod) public rewardPeriods;
    // Mapping to store allocated reward ratio for each period
    mapping(uint256 => uint256) public rewardPeriodAllocatedRatios;
    // Info of each user that stakes tokens (stakedToken)
    mapping(address => UserInfo) public userInfo;

    /*//////////////////////////////////////////////////////////////
                               VELRDS
    //////////////////////////////////////////////////////////////*/
    struct Point {
        int128 bias; // Voting weight
        int128 slope; // Multiplier factor to get voting weight at a given time
        uint256 timestamp;
        uint256 blockNumber;
    }

    bool public isVELrdsInitialized;
    // A global point of time.
    uint256 public epoch;
    // An array of points (global).
    Point[] public pointHistory;
    // Mapping (user => Point) to keep track of user point of a given epoch (index of Point is epoch)
    mapping(address => Point[]) public userPointHistory;
    // Mapping (user => epoch) to keep track which epoch user at
    mapping(address => uint256) public userPointEpoch;
    // Mapping (round off timestamp to week => slopeDelta) to keep track slope changes over epoch
    mapping(uint256 => int128) public slopeChanges;
    uint256 public constant WEEK = 7 days;
    // MAX_LOCK 209 weeks - 1 seconds
    uint256 public constant MAX_LOCK = (209 * WEEK) - 1;
    uint256 public constant MULTIPLIER = 10**18;


    modifier onlyAdmin() {
        require(msg.sender == address(admin), "not Admin");
        _;
    }

    constructor() {}

    /// @inheritdoc IValidator
    function initialize(
        address _admin,
        address _token,
        address _owner,
        uint256 _validatorId,
        bool _isClaimed
    ) external nonReentrant {
        if (factory != address(0)) revert FactoryAlreadySet();
        factory = msg.sender;
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

        isVELrdsInitialized =  false;
        isClaimed = _isClaimed;
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
            totalReward: _totalReward
        });
        
        if(!isVELrdsInitialized) {
            pointHistory.push(Point({bias: 0, slope: 0, timestamp: block.timestamp, blockNumber: block.number}));
            isVELrdsInitialized = true;
        }
        
        IValidatorFactory(factory).AddTotalValidators(_startTime, _endTime, _totalReward);

        rewardPeriodAllocatedRatios[currentRewardPeriodIndex - 1] = 1;
    }

    /*//////////////////////////////////////////////////////////////
                               VALIDATOR
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IValidator
    function createLock(uint256 _amount, uint256 _lockDuration) external nonReentrant {
        if (!_isValidLockDuration(_lockDuration)) revert InvalidLockDuration();
        if (_amount == 0) revert ZeroAmount();
        if (_lockDuration == 0) revert ZeroDuration();
        if (!_isRewardPeriodActive()) revert RewardPeriodNotActive();

        UserInfo storage user = userInfo[msg.sender];
        if (user.amount > 0 || user.lockStartTime > 0) revert AllreadyLocked();

        _deposit(msg.sender, _amount, _lockDuration, user);
    }

    /// @inheritdoc IValidator
    function increaseAmount(uint256 _amount) external nonReentrant {
        if (_amount == 0) revert ZeroAmount();
        if (!_isRewardPeriodActive()) revert RewardPeriodNotActive();

        UserInfo storage user = userInfo[msg.sender];
        if (user.amount == 0) revert NoLockCreated();

        _deposit(msg.sender, _amount, 0, user);
    }

    /// @inheritdoc IValidator
    function extendDuration(uint256 _lockDuration) external nonReentrant {
        if (!_isValidLockDuration(_lockDuration)) revert InvalidLockDuration();
        if (_lockDuration == 0) revert ZeroDuration();
        if (!_isRewardPeriodActive()) revert RewardPeriodNotActive();

        UserInfo storage user = userInfo[msg.sender];
        if (user.amount == 0) revert NoLockCreated();

        _deposit(msg.sender, 0, _lockDuration, user);
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
            // user.accruedRewards[i] += pending;
        }

        (uint256 userClaimAmount, uint256 feeAmount) = _claim(totalPending);

        user.rewardDebt = (user.amount * accTokenPerShare) / PRECISION_FACTOR;

        emit Claim(msg.sender, userClaimAmount, feeAmount);
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
            // user.accruedRewards[i] += pending;
        }

        (uint256 userClaimAmount, uint256 feeAmount) = _claim(totalPending);

        IERC20(rewardPeriods[currentRewardPeriodIndex - 1].stakeToken).safeTransfer(address(msg.sender), user.amount);

        totalStaked -= user.amount;
        delete userInfo[msg.sender];

        emit Withdraw(msg.sender, user.amount, userClaimAmount, feeAmount);
    }

    /// @notice Gets the pending rewards for a user.
    /// @param _userAddress The address of the user to query.
    /// @return The amount of pending rewards for the user.
    function getUserPendingReward(address _userAddress) external view returns (uint256) {
        UserInfo memory user = userInfo[_userAddress];
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

    function _deposit(address _for, uint256 _amount, uint256 _lockDuration, UserInfo storage _user) internal {
        _updateValidator();

        UserInfo memory _prevUser = UserInfo(_user.amount, _user.lockStartTime, _user.lockEndTime, _user.rewardDebt);

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

        // Handling checkpoint here
        _checkpoint(_for, _prevUser, _user);

        _prevUser.rewardDebt = (_prevUser.amount * accTokenPerShare) / PRECISION_FACTOR;

        IValidatorFactory(factory).AddTotalStakedAmount(_amount);
        IValidatorFactory(factory).AddTotalStakedWallet();

        emit Deposit(msg.sender, _amount, _lockDuration, _prevUser.lockEndTime);
    }

    function _claim(uint256 _pending) internal returns (uint256 userClaimAmount, uint256 feeAmount) {
        if (_pending == 0) return (0, 0);

        if (IERC20(rewardPeriods[currentRewardPeriodIndex - 1].rewardToken).balanceOf(address(this)) < _pending) revert NotEnoughRewardToken();

        feeAmount = (_pending * claimFee) / 10000; // claimFee (30 = 0.3%)
        userClaimAmount = _pending - feeAmount;

        IERC20(rewardPeriods[currentRewardPeriodIndex - 1].rewardToken).safeTransfer(owner, feeAmount);
        IERC20(rewardPeriods[currentRewardPeriodIndex - 1].rewardToken).safeTransfer(msg.sender, userClaimAmount);
        
        IValidatorFactory(factory).SubTotalStakedAmount(_pending);
        IValidatorFactory(factory).SubTotalStakedWallet();
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
            RewardPeriod memory period = rewardPeriods[i];
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
        RewardPeriod memory period = rewardPeriods[index];

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
        RewardPeriod memory period = rewardPeriods[_periodIndex];
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




    
    /*//////////////////////////////////////////////////////////////
                               VELRDS
    //////////////////////////////////////////////////////////////*/

    /// @notice Return the voting weight of a givne user
    /// @param _user The address of a user
    function balanceOf(address _user) external view returns (uint256) {
        return _balanceOf(_user, block.timestamp);
    }

    function _balanceOf(address _user, uint256 _timestamp) internal view returns (uint256) {
        uint256 _epoch = userPointEpoch[_user];
        if (_epoch == 0) {
            return 0;
        }
        Point memory _lastPoint = userPointHistory[_user][_epoch];
        _lastPoint.bias =
            _lastPoint.bias -
            (_lastPoint.slope * SafeCast.toInt128(int256(_timestamp - _lastPoint.timestamp)));
        if (_lastPoint.bias < 0) {
            _lastPoint.bias = 0;
        }
        return SafeCast.toUint256(_lastPoint.bias);
    }
    /// @notice Record global and per-user slope to checkpoint
    /// @param _address User's wallet address. Only global if 0x0
    /// @param _prevUser User's previous locked balance and end lock time
    /// @param _newUser User's new locked balance and end lock time
    function _checkpoint( address _address, UserInfo memory _prevUser, UserInfo memory _newUser) internal {
        Point memory _userPrevPoint = Point({slope: 0, bias: 0, timestamp: 0, blockNumber: 0});
        Point memory _userNewPoint = Point({slope: 0, bias: 0, timestamp: 0, blockNumber: 0});

        int128 _prevSlopeDelta = 0;
        int128 _newSlopeDelta = 0;
        uint256 _epoch = epoch;

        // if not 0x0, then update user's point
        if (_address != address(0)) {
            // Calculate slopes and biases according to linear decay graph
            // slope = lockedAmount / MAX_LOCK => Get the slope of a linear decay graph
            // bias = slope * (lockedEnd - currentTimestamp) => Get the voting weight at a given time
            // Kept at zero when they have to
            if (_prevUser.lockEndTime > block.timestamp && _prevUser.amount > 0) {
                // Calculate slope and bias for the prev point
                _userPrevPoint.slope = SafeCast.toInt128(int256(_prevUser.amount)) / SafeCast.toInt128(int256(MAX_LOCK));
                _userPrevPoint.bias =
                    _userPrevPoint.slope *
                    SafeCast.toInt128(int256(_prevUser.lockEndTime - block.timestamp));
            }
            if (_newUser.lockEndTime > block.timestamp && _newUser.amount > 0) {
                // Calculate slope and bias for the new point
                _userNewPoint.slope = SafeCast.toInt128(int256(_newUser.amount)) / SafeCast.toInt128(int256(MAX_LOCK));
                _userNewPoint.bias = _userNewPoint.slope * SafeCast.toInt128(int256(_newUser.lockEndTime - block.timestamp));
            }

            // Handle user history here
            // Do it here to prevent stack overflow
            uint256 _userEpoch = userPointEpoch[_address];
            // If user never ever has any point history, push it here for him.
            if (_userEpoch == 0) {
                userPointHistory[_address].push(_userPrevPoint);
            }

            // Shift user's epoch by 1 as we are writing a new point for a user
            userPointEpoch[_address] = _userEpoch + 1;

            // Update timestamp & block number then push new point to user's history
            _userNewPoint.timestamp = block.timestamp;
            _userNewPoint.blockNumber = block.number;
            userPointHistory[_address].push(_userNewPoint);

            // Read values of scheduled changes in the slope
            // _prevUser.lockEndTime can be in the past and in the future
            // _newUser.lockEndTime can ONLY be in the FUTURE unless everything expired (anything more than zeros)
            _prevSlopeDelta = slopeChanges[_prevUser.lockEndTime];
            if (_newUser.lockEndTime != 0) {
                // Handle when _newUser.lockEndTime != 0
                if (_newUser.lockEndTime == _prevUser.lockEndTime) {
                    // This will happen when user adjust lock but end remains the same
                    // Possibly when user deposited more LRDS to his locker
                    _newSlopeDelta = _prevSlopeDelta;
                } else {
                    // This will happen when user increase lock
                    _newSlopeDelta = slopeChanges[_newUser.lockEndTime];
                }
            }
        }

        // Handle global states here
        Point memory _lastPoint = Point({bias: 0, slope: 0, timestamp: block.timestamp, blockNumber: block.number});
        if (_epoch > 0) {
            // If _epoch > 0, then there is some history written
            // Hence, _lastPoint should be pointHistory[_epoch]
            // else _lastPoint should an empty point
            _lastPoint = pointHistory[_epoch];
        }
        // _lastCheckpoint => timestamp of the latest point
        // if no history, _lastCheckpoint should be block.timestamp
        // else _lastCheckpoint should be the timestamp of latest pointHistory
        uint256 _lastCheckpoint = _lastPoint.timestamp;

        // initialLastPoint is used for extrapolation to calculate block number
        // (approximately, for xxxAt methods) and save them
        // as we cannot figure that out exactly from inside contract
        Point memory _initialLastPoint = Point({
            bias: 0,
            slope: 0,
            timestamp: _lastPoint.timestamp,
            blockNumber: _lastPoint.blockNumber
        });

        // If last point is already recorded in this block, _blockSlope=0
        // That is ok because we know the block in such case
        uint256 _blockSlope = 0;
        if (block.timestamp > _lastPoint.timestamp) {
            // Recalculate _blockSlope if _lastPoint.timestamp < block.timestamp
            // Possiblity when epoch = 0 or _blockSlope hasn't get updated in this block
            _blockSlope =
                (MULTIPLIER * (block.number - _lastPoint.blockNumber)) /
                (block.timestamp - _lastPoint.timestamp);
        }

        // Go over weeks to fill history and calculate what the current point is
        uint256 _weekCursor = _timestampToFloorWeek(_lastCheckpoint);
        for (uint256 i = 0; i < 255; i++) {
            // This logic will works for 5 years, if more than that vote power will be broken 😟
            // Bump _weekCursor a week
            _weekCursor = _weekCursor + WEEK;
            int128 _slopeDelta = 0;
            if (_weekCursor > block.timestamp) {
                // If the given _weekCursor go beyond block.timestamp,
                // We take block.timestamp as the cursor
                _weekCursor = block.timestamp;
            } else {
                // If the given _weekCursor is behind block.timestamp
                // We take _slopeDelta from the recorded slopeChanges
                // We can use _weekCursor directly because key of slopeChanges is timestamp round off to week
                _slopeDelta = slopeChanges[_weekCursor];
            }
            // Calculate _biasDelta = _lastPoint.slope * (_weekCursor - _lastCheckpoint)
            int128 _biasDelta = _lastPoint.slope * SafeCast.toInt128(int256((_weekCursor - _lastCheckpoint)));
            _lastPoint.bias = _lastPoint.bias - _biasDelta;
            _lastPoint.slope = _lastPoint.slope + _slopeDelta;
            if (_lastPoint.bias < 0) {
                // This can happen
                _lastPoint.bias = 0;
            }
            if (_lastPoint.slope < 0) {
                // This cannot happen, just make sure
                _lastPoint.slope = 0;
            }
            // Update _lastPoint to the new one
            _lastCheckpoint = _weekCursor;
            _lastPoint.timestamp = _weekCursor;
            // As we cannot figure that out block timestamp -> block number exactly
            // when query states from xxxAt methods, we need to calculate block number
            // based on _initalLastPoint
            _lastPoint.blockNumber =
                _initialLastPoint.blockNumber +
                ((_blockSlope * ((_weekCursor - _initialLastPoint.timestamp))) / MULTIPLIER);
            _epoch = _epoch + 1;
            if (_weekCursor == block.timestamp) {
                // Hard to be happened, but better handling this case too
                _lastPoint.blockNumber = block.number;
                break;
            } else {
                pointHistory.push(_lastPoint);
            }
        }
        // Now, each week pointHistory has been filled until current timestamp (round off by week)
        // Update epoch to be the latest state
        epoch = _epoch;

        if (_address != address(0)) {
            // If the last point was in the block, the slope change should have been applied already
            // But in such case slope shall be 0
            _lastPoint.slope = _lastPoint.slope + _userNewPoint.slope - _userPrevPoint.slope;
            _lastPoint.bias = _lastPoint.bias + _userNewPoint.bias - _userPrevPoint.bias;
            if (_lastPoint.slope < 0) {
                _lastPoint.slope = 0;
            }
            if (_lastPoint.bias < 0) {
                _lastPoint.bias = 0;
            }
        }

        // Record the new point to pointHistory
        // This would be the latest point for global epoch
        pointHistory.push(_lastPoint);

        if (_address != address(0)) {
            // Schedule the slope changes (slope is going downward)
            // We substract _newSlopeDelta from `_newUser.lockEndTime`
            // and add _prevSlopeDelta to `_prevUser.lockEndTime`
            if (_prevUser.lockEndTime > block.timestamp) {
                // _prevSlopeDelta was <something> - _userPrevPoint.slope, so we offset that first
                _prevSlopeDelta = _prevSlopeDelta + _userPrevPoint.slope;
                if (_newUser.lockEndTime == _prevUser.lockEndTime) {
                    // Handle the new deposit. Not increasing lock.
                    _prevSlopeDelta = _prevSlopeDelta - _userNewPoint.slope;
                }
                slopeChanges[_prevUser.lockEndTime] = _prevSlopeDelta;
            }
            if (_newUser.lockEndTime > block.timestamp) {
                if (_newUser.lockEndTime > _prevUser.lockEndTime) {
                    // At this line, the old slope should gone
                    _newSlopeDelta = _newSlopeDelta - _userNewPoint.slope;
                    slopeChanges[_newUser.lockEndTime] = _newSlopeDelta;
                }
            }
        }
    }
    
    /// @notice Round off random timestamp to week
    /// @param _timestamp The timestamp to be rounded off
    function _timestampToFloorWeek(uint256 _timestamp) internal pure returns (uint256) {
        return (_timestamp / WEEK) * WEEK;
    }


    /*//////////////////////////////////////////////////////////////
                               OWNER
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IValidator
    function claimFees() external nonReentrant {
        if (msg.sender != owner) revert NotOwner();

        uint256 claimed = ValidatorFees(validatorFees).claimFeesFor(msg.sender);

        emit ClaimFees(msg.sender, claimed);
    }

    /// @notice Sets the deposit or claim fee for the contract.
    /// @param _isDepositFee A boolean indicating whether to set the deposit fee (true) or claim fee (false).
    /// @param _fee The new fee percentage to set.
    /// @dev Only the owner can call this function.
    function setFee(bool _isDepositFee, uint256 _fee) external {
        if (msg.sender != owner) revert NotOwner();
        if (_fee > MAX_FEE) revert FeeTooHigh();
        if (_fee == 0) revert ZeroFee();
        if (_isDepositFee) {
            depositFee = _fee;
        } else {
            claimFee = _fee;
        }
    }
    
    /*//////////////////////////////////////////////////////////////
                               ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Adds a new valid lock duration.
    /// @param _duration The duration to add to valid lock durations.
    /// @dev Only the admin can call this function.
    function addLockDuration(uint256 _duration) external onlyAdmin {
        validLockDurations.push(_duration);
    }

    /// @notice Updates an existing lock duration.
    /// @param _index The index of the lock duration to update.
    /// @param _newDuration The new duration to set.
    /// @dev Only the admin can call this function.
    function updateLockDuration(uint256 _index, uint256 _newDuration) external onlyAdmin {
        if (_index >= validLockDurations.length) revert InvalidLockDuration();
        validLockDurations[_index] = _newDuration;
    }

    /// @notice Removes a lock duration from valid options.
    /// @param _index The index of the lock duration to remove.
    /// @dev Only the admin can call this function.
    function removeLockDuration(uint256 _index) external onlyAdmin {
        if (_index >= validLockDurations.length) revert InvalidLockDuration();

        validLockDurations[_index] = validLockDurations[validLockDurations.length - 1];
        validLockDurations.pop();
    }
}
