// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IValidatorFactory {

    error NotAdmin();
    error PoolAlreadyExists();
    error ZeroAddress();
    error NotEnoughAmount();
    error NotEnoughWallet();
    error NotRegisteredValidator();
    
    event ValidatorCreated(address indexed owner, address validator, uint256 validatorLength);

    /// @notice Returns the total number of validators in the system.
    /// @dev This function provides the length of the validator list, indicating how many validators exist in the contract.
    /// @return uint256 The total number of validators.
    function allValidatorsLength() external view returns (uint256);

    /// @notice Checks if the provided address is a registered validator.
    /// @dev This function is used to verify if an address is recognized as a validator in the system.
    /// @param validator The address to check.
    /// @return bool True if the address is a validator, false otherwise.
    function isValidatorl(address validator) external view returns (bool);

    /// @notice Creates a new validator for a given owner, quality, and verifier.
    /// @dev This function is used to create a new validator, initializing it with the provided token address, owner address, and quality level.
    /// @param _token The address of the LRDS.
    /// @param _owner The address of the validator's owner.
    /// @param _quality The quality level of the new validator.
    /// @param _verifier The address of the verifier.
    /// @return validator The address of the newly created validator.
    function createValidator(address _token, address _owner, uint256 _quality, address _verifier) external returns (address validator);

    /// @notice Increases the total staked amount by the specified amount.
    /// @dev This function is used to add a specified amount to the total staked amount across the system.
    /// @param _amount The amount to increase the total staked amount by.
    function addTotalStakedAmount(uint256 _amount) external;

    /// @notice Decreases the total staked amount by the specified amount.
    /// @dev This function is used to subtract a specified amount from the total staked amount across the system.
    /// @param _amount The amount to decrease the total staked amount by.
    function subTotalStakedAmount(uint256 _amount) external;

    /// @notice Increases the total number of staked wallets.
    /// @dev This function is used to increase the number of wallets that have staked tokens in the system.
    function addTotalStakedWallet() external;

    /// @notice Decreases the total number of staked wallets.
    /// @dev This function is used to decrease the number of wallets that have staked tokens in the system.
    function subTotalStakedWallet() external;

    /// @notice Adds a new validator to the total validators list with the specified reward parameters.
    /// @dev This function is used to register a new validator to the system with the total reward parameters, including the start and end time for the reward period.
    /// @param _startTime The start time of the reward period for the new validator.
    /// @param _endTime The end time of the reward period for the new validator.
    /// @param _totalReward The total reward allocated to the new validator for the reward period.
    function addTotalValidators(uint256 _startTime, uint256 _endTime, uint256 _totalReward) external;

    /// @notice Returns the minimum amount required for a given quality level of validator.
    /// @dev This function is used to determine the minimum staked amount required for a validator of a certain quality level.
    /// @param quality The quality level of the validator.
    /// @return uint256 The minimum amount required for the specified quality level.
    function minAmountForQuality(uint256 quality) external returns (uint256);

    /// @notice Returns an array of all validator addresses in the system.
    /// @dev This function is used to retrieve all validator addresses, providing a complete list of validators in the system.
    /// @return address[] The list of all validator addresses.
    function getValidators() external view returns (address[] memory);

}