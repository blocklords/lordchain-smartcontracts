// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/proxy/Clones.sol";

import "./interfaces/IValidatorFactory.sol";
import "./interfaces/IValidator.sol";

contract  ValidatorFactory is IValidatorFactory {
    address public immutable implementation;

    address public pauser;
    address public feeManager;
    address public voter;
    address public admin;

    address[] public allValidators;
    
    mapping(address => mapping(address => mapping(uint256 => address))) private _validatorList;
    mapping(address => uint256) private _validatorCount; // 用于存储每个钱包地址的 validator 数量
    mapping(address => bool) private _isValidator;
    mapping(address => uint256) public customDepositFee;
    mapping(address => uint256) public customClaimFee;
    mapping(address => bool) public isPaused;

    
    constructor(address _implementation) {
        implementation = _implementation;
        voter = msg.sender;
        pauser = msg.sender;
        feeManager = msg.sender;
        admin = msg.sender;
        isPaused[_implementation] = false;
    }

    /// @inheritdoc IValidatorFactory
    function allValidatorsLength() external view returns (uint256) {
        return allValidators.length;
    }

    /// @inheritdoc IValidatorFactory
    function getValidator(address token, address owner, uint256 _validatorId) external view returns (address) {
        return _validatorList[token][owner][_validatorId];
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

    function setPauseState(address _validator, bool _state) external {
        if (msg.sender != pauser) revert NotPauser();
        isPaused[_validator] = _state;
        emit SetPauseState(_validator, _state);
    }

    function setFeeManager(address _feeManager) external {
        if (msg.sender != feeManager) revert NotFeeManager();
        if (_feeManager == address(0)) revert ZeroAddress();
        feeManager = _feeManager;
        emit SetFeeManager(_feeManager);
    }

    // /// @inheritdoc IValidatorFactory
    // function setDepositCustomFee(address validator, uint256 fee) external {
    //     if (msg.sender != feeManager) revert NotFeeManager();
    //     // if (fee > MAX_FEE && fee != ZERO_FEE_INDICATOR) revert FeeTooHigh();
    //     if (fee > MAX_FEE) revert FeeTooHigh();
    //     if (!_isValidator[validator]) revert InvalidValidator();

    //     customDepositFee[validator] = fee;
    //     emit SetDepositCustomFee(validator, fee);
    // }

    // /// @inheritdoc IValidatorFactory
    // function setClaimCustomFee(address validator, uint256 fee) external {
    //     if (msg.sender != feeManager) revert NotFeeManager();
    //     // if (fee > MAX_FEE && fee != ZERO_FEE_INDICATOR) revert FeeTooHigh();
    //     if (fee > MAX_FEE) revert FeeTooHigh();
    //     if (!_isValidator[validator]) revert InvalidValidator();

    //     customClaimFee[validator] = fee;
    //     emit SetClaimCustomFee(validator, fee);
    // }

    /// @inheritdoc IValidatorFactory
    function createValidator(address _token, address _owner) public returns (address validator) {
        if (_token == address(0)) revert ZeroAddress();
        
        uint256 validatorId = _validatorCount[_owner];

        if (_validatorList[_token][_owner][validatorId] != address(0)) revert PoolAlreadyExists();

        _validatorCount[_owner]++;

        bytes32 salt = keccak256(abi.encodePacked(_token, _owner, validatorId)); // salt includes stable as well, 3 parameters
       
        validator = Clones.cloneDeterministic(implementation, salt);
        
        IValidator(validator).initialize(msg.sender, _token, _owner, validatorId);
        
        _validatorList[_token][_owner][validatorId] = validator;

        allValidators.push(validator);

        _isValidator[validator] = true;

        emit ValidatorCreated(_token, _owner, validator, allValidators.length);
    }

}