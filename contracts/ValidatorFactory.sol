// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/proxy/Clones.sol";

import "./interfaces/IValidatorFactory.sol";
import "./interfaces/IValidator.sol";

contract  ValidatorFactory is IValidatorFactory {

    struct ValidatorInfo {
        uint256 startTime;
        uint256 endTime;
        uint256 totalReward;
    }

    uint256 public totalStakedAmount;
    uint256 public totalStakedWallet;
    uint256 public validatorPeriodCount;

    address public immutable implementation;
    address public pauser;
    address public feeManager;
    address public voter;
    address public admin;

    address[] public allValidators;
    
    mapping(address => bool) private _isValidator;
    mapping(address => bool) public isPaused;
    mapping(uint256 => ValidatorInfo) public totalValidators;
    mapping(uint256 => uint256) public minAmountForQuality;

    modifier onlyAdmin() {
        if (msg.sender != address(admin)) revert NotAdmin();
        _;
    }

    constructor(address _implementation) {
        implementation = _implementation;
        voter = msg.sender;
        pauser = msg.sender;
        feeManager = msg.sender;
        admin = msg.sender;
        isPaused[_implementation] = false;
        
        minAmountForQuality[3] = 400;
        minAmountForQuality[4] = 1000;
        minAmountForQuality[5] = 3000;
        minAmountForQuality[6] = 5000;
        minAmountForQuality[7] = 10000;
    }

    /// @inheritdoc IValidatorFactory
    function allValidatorsLength() external view returns (uint256) {
        return allValidators.length;
    }

    /// @inheritdoc IValidatorFactory
    function getValidators() external view returns (address[] memory) {
        return allValidators;
    }

    /// @inheritdoc IValidatorFactory
    function AddTotalStakedAmount(uint256 _amount) external {
        if (!_isValidator[msg.sender]) revert  NotRegisteredValidator();
        totalStakedAmount += _amount;
    }

    /// @inheritdoc IValidatorFactory
    function SubTotalStakedAmount(uint256 _amount) external {
        if (!_isValidator[msg.sender]) revert  NotRegisteredValidator();
        if (totalStakedAmount < _amount) revert NotEnoughAmount();
        totalStakedAmount -= _amount;
    }

    /// @inheritdoc IValidatorFactory
    function AddTotalStakedWallet() external {
        if (!_isValidator[msg.sender]) revert  NotRegisteredValidator();
        totalStakedWallet++;
    }
    
    /// @inheritdoc IValidatorFactory
    function SubTotalStakedWallet() external {
        if (!_isValidator[msg.sender]) revert  NotRegisteredValidator();
        if (totalStakedWallet < 0) revert NotEnoughWallet();
        totalStakedWallet--;
    }

    /// @inheritdoc IValidatorFactory
    function AddTotalValidators(uint256 _startTime, uint256 _endTime, uint256 _totalReward) external {
        if (!_isValidator[msg.sender]) revert  NotRegisteredValidator();
        totalValidators[validatorPeriodCount++] = ValidatorInfo(_startTime, _endTime, _totalReward);
    }

    function getTotalValidatorRewards() external view returns (uint256) {
        uint256 totalValidatorRewards = 0;

        for (uint256 i = 0; i < validatorPeriodCount; i++) {
            uint256 period = 0;
            if (block.timestamp > totalValidators[i].startTime) {
                period = block.timestamp - totalValidators[i].startTime ;
                if (block.timestamp > totalValidators[i].endTime) {
                    period = totalValidators[i].endTime - totalValidators[i].startTime;
                }
            }

            uint256 duration = totalValidators[i].endTime - totalValidators[i].startTime;
            totalValidatorRewards += (period * totalValidators[i].totalReward) / duration;
        }
        return totalValidatorRewards;
    }

    /// @inheritdoc IValidatorFactory
    function isValidatorl(address pool) external view returns (bool) {
        return _isValidator[pool];
    }

    /// @inheritdoc IValidatorFactory
    function setVoter(address _voter) external {
        if (msg.sender != voter) revert NotVoter();
        voter = _voter;
        emit SetVoter(_voter);
    }

    /// @inheritdoc IValidatorFactory
    function setPauser(address _pauser) external {
        if (msg.sender != pauser) revert NotPauser();
        if (_pauser == address(0)) revert ZeroAddress();
        pauser = _pauser;
        emit SetPauser(_pauser);
    }

    /// @inheritdoc IValidatorFactory
    function setPauseState(address _validator, bool _state) external {
        if (msg.sender != pauser) revert NotPauser();
        isPaused[_validator] = _state;
        emit SetPauseState(_validator, _state);
    }

    /// @inheritdoc IValidatorFactory
    function setFeeManager(address _feeManager) external {
        if (msg.sender != feeManager) revert NotFeeManager();
        if (_feeManager == address(0)) revert ZeroAddress();
        feeManager = _feeManager;
        emit SetFeeManager(_feeManager);
    }

    function setMinAmountForQuality(uint256 quality, uint256 amount) external onlyAdmin {
        minAmountForQuality[quality] = amount;
    }

    /// @inheritdoc IValidatorFactory
    function createValidator(address _token, address _owner, uint256 _quality, address _verifier) external onlyAdmin returns (address validator) {
        uint256 validatorId = allValidators.length;  // Use the length of allValidators array as the validatorId

        bytes32 salt = keccak256(abi.encodePacked(_quality, _owner, validatorId)); // salt includes stable as well, 3 parameters
       
        validator = Clones.cloneDeterministic(implementation, salt);
        
        IValidator(validator).initialize(_token, msg.sender, _owner, validatorId, _quality, _verifier);
    
        allValidators.push(validator);

        _isValidator[validator] = true;

        emit ValidatorCreated(_owner, validator, allValidators.length);
    }

}