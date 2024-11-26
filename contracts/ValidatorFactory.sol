// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

import "./interfaces/IValidatorFactory.sol";
import "./interfaces/IValidator.sol";

contract  ValidatorFactory is IValidatorFactory, Ownable2Step {

    struct ValidatorInfo {
        uint256 startTime;
        uint256 endTime;
        uint256 totalReward;
    }
    
    struct ValidatorStats {
        address validatorAddress;
        uint256 totalStaked;
        uint256 rewardStartTime;
        uint256 rewardEndTime;
        uint256 rewardTotal;
        bool isClaimed;
        uint256 AllocatedValidatorRewards;
    }

    struct BoostStats {
        address validatorAddress;
        uint256 boostRewardTotal;
        uint256 boostStartTime;
        uint256 boostEndTime;
    }

    struct UserStats {
        address validatorAddress;
        uint256 userAmount;
        uint256 lockStartTime;
        uint256 lockEndTime;
        uint256 baseReward;
        uint256 veLRDSBalance;
        bool autoMax;
        uint256 boostReward;
    }

    uint256 public totalStakedAmount;
    uint256 public totalStakedWallet;
    uint256 public validatorPeriodCount;

    address public immutable implementation;
    address public admin;

    address[] public allValidators;
    
    mapping(address => bool) private _isValidator;
    mapping(uint256 => ValidatorInfo) public totalValidators;
    mapping(uint256 => uint256) public minAmountForQuality;
    // Mapping to store the count of nodes based on their quality
    mapping(uint256 => uint256) public nodeCounts;

    modifier onlyAdmin() {
        if (msg.sender != address(admin)) revert NotAdmin();
        _;
    }

    constructor(address _implementation) Ownable(msg.sender) {
        implementation = _implementation;
        admin = msg.sender;
        
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
    function addTotalStakedAmount(uint256 _amount) external {
        if (!_isValidator[msg.sender]) revert  NotRegisteredValidator();
        totalStakedAmount += _amount;
    }

    /// @inheritdoc IValidatorFactory
    function subTotalStakedAmount(uint256 _amount) external {
        if (!_isValidator[msg.sender]) revert  NotRegisteredValidator();
        if (totalStakedAmount < _amount) revert NotEnoughAmount();
        totalStakedAmount -= _amount;
    }

    /// @inheritdoc IValidatorFactory
    function addTotalStakedWallet() external {
        if (!_isValidator[msg.sender]) revert  NotRegisteredValidator();
        totalStakedWallet++;
    }
    
    /// @inheritdoc IValidatorFactory
    function subTotalStakedWallet() external {
        if (!_isValidator[msg.sender]) revert  NotRegisteredValidator();
        if (totalStakedWallet == 0) revert NotEnoughWallet();
        totalStakedWallet--;
    }

    /// @inheritdoc IValidatorFactory
    function addTotalValidators(uint256 _startTime, uint256 _endTime, uint256 _totalReward) external {
        if (!_isValidator[msg.sender]) revert  NotRegisteredValidator();
        if ((_endTime <= _startTime)) revert InvalidTimePeriod();
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

    function setMinAmountForQuality(uint256 quality, uint256 amount) external onlyAdmin {
        minAmountForQuality[quality] = amount;
    }

    /// @inheritdoc IValidatorFactory
    function createValidator(address _token, address _owner, uint256 _quality, address _verifier) external onlyAdmin returns (address validator) {
        // Use the length of allValidators array as the validatorId
        uint256 validatorId = allValidators.length; 
        
        // Get the current counter value for the specified quality, starting from 1
        uint256 currentQualityCount = nodeCounts[_quality] + 1;

        // Update the counter
        nodeCounts[_quality] = currentQualityCount;
         
        // salt includes stable as well, 3 parameters
        bytes32 salt = keccak256(abi.encodePacked(_quality, _owner, validatorId)); 
       
        validator = Clones.cloneDeterministic(implementation, salt);
        
        IValidator(validator).initialize(_token, msg.sender, _owner, validatorId, _quality, _verifier, currentQualityCount);
    
        allValidators.push(validator);

        _isValidator[validator] = true;

        emit ValidatorCreated(_owner, validator, allValidators.length);
    }

    /**
    * @dev Transfers ownership of the contract to a new account (`_newOwner`).
    * This function overrides the `transferOwnership` function from the parent contract 
    * to call the parent contract's implementation of ownership transfer.
    * Only the current owner can call this function.
    *
    * @param _newOwner The address to transfer ownership to.
    */
    function transferOwnership(address _newOwner) public override onlyOwner {
        super.transferOwnership(_newOwner);
    }
    
    /**
    * @dev Allows the nominated address to accept ownership transfer.
    * This function overrides the `acceptOwnership` function from the parent contract 
    * to call the parent contract's implementation of accepting ownership.
    * The nominated address must call this function to complete the ownership transfer.
    */
    function acceptOwnership() public override {
        super.acceptOwnership();
    }

}