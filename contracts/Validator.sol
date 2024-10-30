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
        uint256 amount;         // How many staked tokens the user has provided
        uint256 lockStartTime;  // lock start time.
        uint256 lockEndTime;    // lock end time.
        uint256 rewardDebt;     // Reward debt
    }

    string private _name;
    string private _type;
    address private _voter;
    
    uint256 public totalStaked;
    // Accrued token per share
    uint256 public accTokenPerShare;
    // The precision factor
    uint256 public PRECISION_FACTOR = 10 ** 12;
    uint256 public depositFee;
    uint256 public claimFee;
    uint256 public constant MAX_FEE = 300; // 3%

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


    RewardPeriod public rewardPeriod;

    // Info of each user that stakes tokens (stakedToken)
    mapping(address => UserInfo) public userInfo;

    constructor() ERC20("", "") ERC20Permit("") {}

    /// @inheritdoc IValidator
    function initialize(address _admin, address _token, address _owner, uint256 _validatorId) external nonReentrant {
        if (factory != address(0)) revert FactoryAlreadySet();
        factory = _msgSender();
        _voter = IValidatorFactory(factory).voter();
        (admin, token, owner, validatorId) = (_admin, _token, _owner, _validatorId);

        validatorFees = address(new ValidatorFees(token));

        string memory symbol = ERC20(_token).symbol();
        _name = string(abi.encodePacked("Stable AMM - ", symbol));
        
        depositFee = 5; // 0.05%
        claimFee = 30; // 0.3%
        
        validLockDurations.push(0);
        validLockDurations.push(2 weeks);
        validLockDurations.push(13 weeks);
        validLockDurations.push(24 weeks);
        validLockDurations.push(365 days);
        validLockDurations.push(365 * 2 days);
    }

    /*
     * @notice setRewardPeriod the contract
     * @param _stakedToken: staked token address
     * @param _rewardToken: reward token address
     * @param _totalReward: amount of reward tokens (in rewardToken)
     * @param _startTime: start time
     * @param _endTime: end time
     */
    function setRewardPeriod(
        uint256 _startTime,
        uint256 _endTime,
        address _stakeToken,
        address _rewardToken,
        uint256 _totalReward
    ) external nonReentrant {
        if (msg.sender != admin) revert NotAdmin();

            rewardPeriod = RewardPeriod({
            startTime: _startTime,
            endTime: _endTime,
            stakeToken: _stakeToken,
            rewardToken: _rewardToken,
            totalReward: _totalReward
        });
    }

    /// @inheritdoc IValidator
    function claimFees() external nonReentrant {
        if (msg.sender != owner) revert NotOwner();

        uint256 claimed = ValidatorFees(validatorFees).claimFeesFor(msg.sender);

        emit ClaimFees(msg.sender, claimed);  
    }

    function createLock(uint256 _amount, uint256 _lockDuration) external nonReentrant {
        if (!isValidLockDuration(_lockDuration)) revert InvalidLockDuration();
        if (_amount == 0) revert ZeroAmount();
        if (_lockDuration == 0) revert ZeroDuration();

        UserInfo storage user = userInfo[msg.sender];
        if (user.amount > 0 || user.lockStartTime > 0) revert AllreadyLocked();

        _deposit(_amount, _lockDuration, user);
    }

    function increaseAmount(uint256 _amount) external nonReentrant {
        if (_amount == 0) revert ZeroAmount();

        UserInfo storage user = userInfo[msg.sender];
        if (user.amount == 0) revert NoLockCreated();

        _deposit(_amount, 0, user);
    }

    function extendDuration(uint256 _lockDuration) external nonReentrant {
        if (_lockDuration == 0) revert ZeroDuration();

        UserInfo storage user = userInfo[msg.sender];
        if (user.amount == 0) revert NoLockCreated();

        _deposit(0, _lockDuration, user);
    }

    function _deposit(uint256 _amount, uint256 _lockDuration, UserInfo storage _user) internal {

        _updateValidator();

        if (_amount > 0) {
            
            uint256 fee = (_amount * depositFee) / 10000; //  depositFee (5 = 0.05%)
            uint256 amountAfterFee = _amount - fee;

            if (amountAfterFee <= 0) revert InsufficientAmount();
            
            // Transfer the staked amount to the contract
            IERC20(rewardPeriod.stakeToken).safeTransferFrom(msg.sender, address(this), amountAfterFee);
            
            if (fee > 0) {
                IERC20(rewardPeriod.stakeToken).safeTransferFrom(msg.sender, validatorFees, fee); // transfer to ValidatorFees address
            }

            _user.amount += amountAfterFee;
            totalStaked  += amountAfterFee;
            
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

    function withdraw() external nonReentrant {

        UserInfo storage user = userInfo[msg.sender];

        if (user.amount == 0) revert ZeroAmount();
        if (block.timestamp < user.lockEndTime) revert TimeNotUp();

        _updateValidator();

        if(IERC20(rewardPeriod.stakeToken).balanceOf(address(this)) < user.amount) revert NotEnoughStakeToken();
        
        uint256 pending = (user.amount * accTokenPerShare) / PRECISION_FACTOR - user.rewardDebt;
        
        (uint256 userClaimAmount, uint256 feeAmount) = _claim(pending);

        IERC20(rewardPeriod.stakeToken).safeTransfer(address(msg.sender), user.amount);

        totalStaked       -= user.amount;
        delete userInfo[msg.sender];

        emit Withdraw(msg.sender, user.amount, userClaimAmount, feeAmount);
    }

    function claim() external nonReentrant {

        UserInfo storage user = userInfo[msg.sender];

        if (user.amount == 0) revert NoStakeFound();

        _updateValidator(); 

        uint256 pending = (user.amount * accTokenPerShare) / PRECISION_FACTOR - user.rewardDebt;

        (uint256 userClaimAmount, uint256 feeAmount) = _claim(pending);

        emit Claim(msg.sender, userClaimAmount, feeAmount);
    }

    function _claim(uint256 pending) internal returns (uint256 userClaimAmount, uint256 feeAmount) {
        if (pending == 0) return (0, 0);

        if (IERC20(rewardPeriod.rewardToken).balanceOf(address(this)) < pending) revert NotEnoughRewardToken();

        feeAmount = (pending * claimFee) / 10000; // claimFee (30 = 0.3%)
        userClaimAmount = pending - feeAmount;

        IERC20(rewardPeriod.rewardToken).safeTransfer(owner, feeAmount);
            
        IERC20(rewardPeriod.rewardToken).safeTransfer(msg.sender, userClaimAmount);
    }

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

    function addLockDuration(uint256 _duration) external nonReentrant {
        if (msg.sender != admin) revert NotAdmin();
        validLockDurations.push(_duration);
    }

    function updateLockDuration(uint256 _index, uint256 _newDuration) external nonReentrant {
        if (msg.sender != admin) revert NotAdmin();
        if (_index >= validLockDurations.length) revert InvalidLockDuration();
        validLockDurations[_index] = _newDuration;
    }

    function removeLockDuration(uint256 _index) external nonReentrant {
        if (msg.sender != admin) revert NotAdmin();
        if (_index >= validLockDurations.length) revert InvalidLockDuration();

        validLockDurations[_index] = validLockDurations[validLockDurations.length - 1];
        validLockDurations.pop(); 
    }

    function isValidLockDuration(uint256 _lockDuration) internal view returns (bool) {
        for (uint256 i = 0; i < validLockDurations.length; i++) {
            if (validLockDurations[i] == _lockDuration) {
                return true;
            }
        }
        return false;
    }

    function _updateValidator() internal {
        if (block.timestamp  <= lastRewardTime) return;

        if (totalStaked == 0) {
            lastRewardTime = block.timestamp;
            return;
        }
        uint256 totalReward = rewardPeriod.totalReward;
        uint256 startTime = rewardPeriod.startTime;
        uint256 endTime = rewardPeriod.endTime;

        uint256 rewardPerSecond = totalReward / (endTime - startTime);
        uint256 multiplier = _getMultiplier(lastRewardTime, block.timestamp, endTime);
        uint256 lrdsReward = multiplier * rewardPerSecond;
        accTokenPerShare = accTokenPerShare + (lrdsReward * PRECISION_FACTOR) / totalStaked;

        lastRewardTime = block.timestamp;
    }
    
    function _getMultiplier(uint256 _from, uint256 _to, uint256 _endTime) internal pure returns (uint256) {
        if (_to <= _endTime) {
            return _to - _from;
        } else if (_from >= _endTime) {
            return 0;
        } else {
            return _endTime - _from;
        }
    }

}