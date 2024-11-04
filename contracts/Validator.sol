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
        bool autoMax;
    }

    uint256 public constant DEPOSIT_MAX_FEE = 100; // 1%
    uint256 public constant CLAIM_MAX_FEE = 500;   // 5%
    uint256 public constant WEEK = 7 days;
    uint256 public constant MAX_LOCK = (209 * WEEK) - 1; // MAX_LOCK 209 weeks - 1 seconds
    uint256 public constant MIN_LOCK = WEEK;
    uint256 public constant MULTIPLIER = 10**18;

    bool public isClaimed;

    string public _name;

    uint256 public lastRewardTime;
    uint256 public totalStaked;
    // Accrued token per share
    uint256 public accTokenPerShare;
    // The precision factor
    uint256 public PRECISION_FACTOR;
    uint256 public depositFee;
    uint256 public claimFee;
    uint256 public validatorId;
    uint256 public currentRewardPeriodIndex;
    uint256 public quality;

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
    address public verifier;                   // Address of the verifier for signature verification
    address public masterValidator;


    mapping(uint256 => RewardPeriod) public rewardPeriods;
    // Mapping to store allocated reward ratio for each period
    mapping(uint256 => uint256) public rewardPeriodAllocatedRatios;
    // Info of each user that stakes tokens (stakedToken)
    mapping(address => UserInfo) public userInfo;
    mapping(uint256 => uint256) public nodeCounts;

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


    modifier onlyAdmin() {
        if (msg.sender != address(admin)) revert NotAdmin();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != address(admin)) revert NotOwner();
        _;
    }

    constructor() {}

    /// @inheritdoc IValidator
    function initialize(
        address _admin,
        address _token,
        address _owner,
        uint256 _validatorId,
        bool _isClaimed,
        uint256 _quality
    ) external nonReentrant {
        if (factory != address(0)) revert FactoryAlreadySet();
        factory = msg.sender;
        _voter = IValidatorFactory(factory).voter();
        (admin, token, owner, validatorId, quality) = (_admin, _token, _owner, _validatorId, _quality);

        depositFee = 100; // 1%
        claimFee = 500; // 5%
        PRECISION_FACTOR = 10 ** 12;

        validatorFees = address(new ValidatorFees(token));

        string memory nodeType;
        if (_quality == 0) {
            nodeType = "Master Validator";
            depositFee = 0;
            claimFee = 0;
        } else if (_quality == 1) {
            nodeType = "Standard Validator";
        } else if (_quality == 2) {
            nodeType = "Special Validator";
        } else if (_quality == 3) {
            nodeType = "Rare Validator";
        } else if (_quality == 4) {
            nodeType = "Epic Validator";
        } else if (_quality == 5) {
            nodeType = "Legendary Validator";
        } else if (_quality == 6) {
            nodeType = "Super Validator";
        } else {
            revert QualityWrong();
        }
        nodeCounts[_quality]++;
        _name = string(abi.encodePacked(nodeType, " ", Strings.toString(nodeCounts[_quality])));

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
        if (_amount == 0) revert ZeroAmount();
        if (_lockDuration == 0 || _lockDuration < MIN_LOCK || _lockDuration > MAX_LOCK) revert WrongDuration();
        if (!_isRewardPeriodActive()) revert RewardPeriodNotActive();

        UserInfo storage user = userInfo[msg.sender];
        if (user.amount > 0 || user.lockStartTime > 0) revert AllreadyLocked();

        IValidatorFactory(factory).AddTotalStakedWallet();

        _deposit(msg.sender, _amount, _lockDuration, user);
    }

    /// @inheritdoc IValidator
    function increaseAmount(uint256 _amount) external nonReentrant {
        if (_amount == 0) revert ZeroAmount();
        if (!_isRewardPeriodActive()) revert RewardPeriodNotActive();

        UserInfo storage user = userInfo[msg.sender];
        if (user.amount == 0) revert NoLockCreated();
        if (user.autoMax == false) {
            if (block.timestamp > user.lockEndTime) revert LockTimeExceeded();
        }

        _deposit(msg.sender, _amount, 0, user);
    }

    /// @inheritdoc IValidator
    function extendDuration(uint256 _lockDuration) external nonReentrant {
        if (_lockDuration == 0 || _lockDuration < MIN_LOCK || _lockDuration > MAX_LOCK) revert WrongDuration();
        if (!_isRewardPeriodActive()) revert RewardPeriodNotActive();

        UserInfo storage user = userInfo[msg.sender];
        if (user.amount == 0) revert NoLockCreated();
        if (user.autoMax == true) revert AutoMaxTime();
        if (user.lockEndTime + _lockDuration > MAX_LOCK) revert GreaterThenMaxTime();

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
        if (user.autoMax == true) revert AutoMaxTime();

        _updateValidator();

        if (IERC20(rewardPeriods[currentRewardPeriodIndex - 1].stakeToken).balanceOf(address(this)) < user.amount) revert NotEnoughStakeToken();

        uint256 totalPending = 0;
        for (uint256 i = 0; i < currentRewardPeriodIndex; i++) {
            uint256 pending = _calculatePending(user, i);
            totalPending += pending;
            // user.accruedRewards[i] += pending;
        }

        (uint256 userWithdrawAmount, uint256 feeAmount) = _claim(totalPending);

        IERC20(rewardPeriods[currentRewardPeriodIndex - 1].stakeToken).safeTransfer(address(msg.sender), user.amount);
        
        user.rewardDebt = (user.amount * accTokenPerShare) / PRECISION_FACTOR;

        totalStaked -= user.amount;
        delete userInfo[msg.sender];

        IValidatorFactory(factory).SubTotalStakedAmount(userWithdrawAmount);
        IValidatorFactory(factory).SubTotalStakedWallet();
        

        emit Withdraw(msg.sender, user.amount, userWithdrawAmount, feeAmount);
    }
    
    /// @inheritdoc IValidator
    function setAutoMax(bool _bool) external nonReentrant {
        UserInfo storage user = userInfo[msg.sender];
        if (user.amount == 0) revert NoLockCreated();
        if (user.autoMax == _bool) revert TheSameValue();
        user.autoMax = _bool;
        user.lockEndTime = block.timestamp + MAX_LOCK;

        emit SetAutoMax(msg.sender, _bool);
    }

    function purchaseValidator(uint256 _np, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s) external nonReentrant{
        if (_deadline < block.timestamp) revert SignatureExpired();
        if (_np <= 0) revert ZeroAmount();
        if (isClaimed == true) revert ValidatorIsClaimed();

        (uint256 amount, bool isAutoMax) = IValidator(masterValidator).getAmountAndAutoMax(msg.sender);
        if (isAutoMax == false) revert AutoMaxNotEnabled();
        
        uint256 requiredAmount = IValidatorFactory(factory).minAmountForQuality(quality);
        if (amount < requiredAmount) revert InsufficientAmount();

        {
            bytes32 message         = keccak256(abi.encodePacked(_np, address(this), _deadline, block.chainid));
            bytes32 hash            = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", message));
            address recover         = ecrecover(hash, _v, _r, _s);

            if (recover != verifier) revert VerificationFailed();
        }

        isClaimed = true;
        owner = msg.sender;

        emit PurchaseValidator(msg.sender, _np);

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

    function getValidatorRewards() external view returns (uint256) {
        uint256 totalRewards = 0;
        for (uint256 i = 0; i < currentRewardPeriodIndex; i++) {
            uint256 period = 0;
            if (block.timestamp > rewardPeriods[i].startTime) {
                period = block.timestamp - rewardPeriods[i].startTime;
                if (block.timestamp > rewardPeriods[i].endTime) {
                    period = rewardPeriods[i].endTime - rewardPeriods[i].startTime;
                }
            }

            uint256 duration = rewardPeriods[i].endTime - rewardPeriods[i].startTime;
            totalRewards += (period * rewardPeriods[i].totalReward) / duration;
        }
        return totalRewards;
    }
    
    function getAmountAndAutoMax(address _userAddress) external view returns (uint256, bool) {
        UserInfo storage info = userInfo[_userAddress];
        return (info.amount, info.autoMax);
    }

    function _deposit(address _for, uint256 _amount, uint256 _lockDuration, UserInfo storage _user) internal {
        _updateValidator();

        UserInfo memory _prevUser = UserInfo(_user.amount, _user.lockStartTime, _user.lockEndTime, _user.rewardDebt, _user.autoMax);
        // UserInfo memory _prevUser = UserInfo(_user.amount, _user.lockStartTime, _user.lockEndTime);

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
            totalStaked += _user.amount;

            if (_lockDuration > 0) {
                _user.lockStartTime = block.timestamp;
                _user.lockEndTime = _lockDuration + block.timestamp;
            }

            IValidatorFactory(factory).AddTotalStakedAmount(amountAfterFee);
        }

        if (_lockDuration > 0 && _amount == 0) {
            _user.lockEndTime += _lockDuration;
        }

        // Handling checkpoint here
        // _checkpoint(_for, _prevUser, _user);

        _prevUser.rewardDebt = (_prevUser.amount * accTokenPerShare) / PRECISION_FACTOR;

        emit Deposit(msg.sender, _amount, _lockDuration, _prevUser.lockEndTime);
    }

    function _claim(uint256 _pending) internal returns (uint256 userClaimAmount, uint256 feeAmount) {
        if (_pending == 0) return (0, 0);

        if (IERC20(rewardPeriods[currentRewardPeriodIndex - 1].rewardToken).balanceOf(address(this)) < _pending) revert NotEnoughRewardToken();

        feeAmount = (_pending * claimFee) / 10000; // claimFee (30 = 0.3%)
        userClaimAmount = _pending - feeAmount;

        IERC20(rewardPeriods[currentRewardPeriodIndex - 1].rewardToken).safeTransfer(owner, feeAmount);
        IERC20(rewardPeriods[currentRewardPeriodIndex - 1].rewardToken).safeTransfer(msg.sender, userClaimAmount);
        
    }

    /// @notice Checks if any reward period is currently active.
    /// @return A boolean indicating if any reward period is active.
    function _isRewardPeriodActive() internal view returns (bool) {
        for (uint256 i = 0; i < currentRewardPeriodIndex; i++) {
            RewardPeriod memory period = rewardPeriods[i];
            if ( block.timestamp >= period.startTime && block.timestamp <= period.endTime) {
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
                               OWNER
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IValidator
    function claimFees() external nonReentrant onlyOwner{
        uint256 claimed = ValidatorFees(validatorFees).claimFeesFor(msg.sender);

        emit ClaimFees(msg.sender, claimed);
    }

    /// @notice Sets the deposit fee for the contract.
    /// @param _fee The new fee percentage to set.
    /// @dev Only the owner can call this function.
    function setDepositFee(uint256 _fee) external nonReentrant onlyOwner {
        if (_fee < 0) revert WrongFee();
        if (_fee > DEPOSIT_MAX_FEE) revert FeeTooHigh();
        depositFee = _fee;

        emit SetDepositFee(msg.sender, _fee);
    }

    // @notice Sets the claim fee for the contract.
    /// @param _fee The new fee percentage to set.
    /// @dev Only the owner can call this function.
    function setClaimFee(uint256 _fee) external nonReentrant onlyOwner {
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
    
    function setMasterValidator(address _validator) external onlyAdmin {
        if (_validator == address(0)) revert ZeroAddress();
        masterValidator = _validator;
    }
}
