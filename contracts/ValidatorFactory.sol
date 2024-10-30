// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/proxy/Clones.sol";

import "./interfaces/IValidatorFactory.sol";
import "./interfaces/IValidator.sol";

contract  ValidatorFactory is IValidatorFactory {
    address public immutable implementation;

    bool public isPaused;
    address public pauser;
    
    uint256 public depositFee;
    uint256 public claimFee;
    uint256 public constant MAX_FEE = 300; // 3%

    address public feeManager;
    address public voter;
    
    mapping(address => mapping(address => address)) private _validatorList;
    address[] public allValidators;
    mapping(address => bool) private _isValidator;
    mapping(address => uint256) public customDepositFee;
    mapping(address => uint256) public customClaimFee;

    
    constructor(address _implementation) {
        implementation = _implementation;
        voter = msg.sender;
        pauser = msg.sender;
        feeManager = msg.sender;
        isPaused = false;
        depositFee = 5; // 0.05%
        claimFee = 30; // 0.3%
    }

    /// @inheritdoc IValidatorFactory
    function allValidatorsLength() external view returns (uint256) {
        return allValidators.length;
    }

    /// @inheritdoc IValidatorFactory
    function getValidator(address token, address owner) external view returns (address) {
        return _validatorList[token][owner];
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

    function setPauser(address _pauser) external {
        if (msg.sender != pauser) revert NotPauser();
        if (_pauser == address(0)) revert ZeroAddress();
        pauser = _pauser;
        emit SetPauser(_pauser);
    }

    function setPauseState(bool _state) external {
        if (msg.sender != pauser) revert NotPauser();
        isPaused = _state;
        emit SetPauseState(_state);
    }

    function setFeeManager(address _feeManager) external {
        if (msg.sender != feeManager) revert NotFeeManager();
        if (_feeManager == address(0)) revert ZeroAddress();
        feeManager = _feeManager;
        emit SetFeeManager(_feeManager);
    }
    
    /// @inheritdoc IValidatorFactory
    function setFee(bool _type, uint256 _fee) external {
        if (msg.sender != feeManager) revert NotFeeManager();
        if (_fee > MAX_FEE) revert FeeTooHigh();
        if (_fee == 0) revert ZeroFee();
        if (_type) {
            depositFee = _fee;
        } else {
            claimFee = _fee;
        }
    }

    /// @inheritdoc IValidatorFactory
    function setDepositCustomFee(address validator, uint256 fee) external {
        if (msg.sender != feeManager) revert NotFeeManager();
        // if (fee > MAX_FEE && fee != ZERO_FEE_INDICATOR) revert FeeTooHigh();
        if (fee > MAX_FEE) revert FeeTooHigh();
        if (!_isValidator[validator]) revert InvalidValidator();

        customDepositFee[validator] = fee;
        emit SetDepositCustomFee(validator, fee);
    }

    /// @inheritdoc IValidatorFactory
    function setClaimCustomFee(address validator, uint256 fee) external {
        if (msg.sender != feeManager) revert NotFeeManager();
        // if (fee > MAX_FEE && fee != ZERO_FEE_INDICATOR) revert FeeTooHigh();
        if (fee > MAX_FEE) revert FeeTooHigh();
        if (!_isValidator[validator]) revert InvalidValidator();

        customClaimFee[validator] = fee;
        emit SetClaimCustomFee(validator, fee);
    }

    /// @inheritdoc IValidatorFactory
    function createValidator(address _token, address _owner) public returns (address validator) {
        if (_token == address(0)) revert ZeroAddress();

        if (_validatorList[_token][_owner] != address(0)) revert PoolAlreadyExists();

        bytes32 salt = keccak256(abi.encodePacked(_token, _owner)); // salt includes stable as well, 3 parameters
       
        validator = Clones.cloneDeterministic(implementation, salt);
        
        IValidator(validator).initialize(_token, _owner);
        
        _validatorList[_token][_owner] = validator;

        allValidators.push(validator);

        _isValidator[validator] = true;

        emit ValidatorCreated(_token, _owner, validator, allValidators.length);
    }
}