// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IValidatorFactory {

    error NotFeeManager();
    error NotPauser();
    error NotVoter();
    error NotAdmin();
    error PoolAlreadyExists();
    error ZeroAddress();
    error NotEnoughAmount();
    error NotEnoughWallet();
    error NotRegisteredValidator();
    
    event SetFeeManager(address feeManager);
    event SetPauser(address pauser);
    event SetPauseState(address validator, bool state);
    event SetVoter(address voter);
    event ValidatorCreated(address indexed owner, address validator, uint256 validatorLength);
    /// @notice Returns the address of the current voter.
    /// @dev This function allows access to the address of the voter who is responsible for validator-related operations.
    /// @return address The address of the voter.
    function voter() external view returns (address);

    /// @notice Returns the total number of validators in the system.
    /// @dev This function provides the length of the validator list, indicating how many validators exist in the contract.
    /// @return uint256 The total number of validators.
    function allValidatorsLength() external view returns (uint256);

    /// @notice Checks if the provided address is a registered validator.
    /// @dev This function is used to verify if an address is recognized as a validator in the system.
    /// @param validator The address to check.
    /// @return bool True if the address is a validator, false otherwise.
    function isValidatorl(address validator) external view returns (bool);

    /// @notice Sets the address of the voter for validator-related operations.
    /// @dev This function allows the contract owner or admin to set the address of the voter, who can then be responsible for validation-related actions.
    /// @param _voter The address of the new voter.
    function setVoter(address _voter) external;

    /// @notice Sets the address of the pauser for contract pause functionality.
    /// @dev This function allows the contract owner or admin to assign the pauser, who has the ability to pause or unpause the contract.
    /// @param _pauser The address of the new pauser.
    function setPauser(address _pauser) external;

    /// @notice Sets the pause state for a specific validator.
    /// @dev This function allows the state of a validator (whether it's paused or not) to be changed. The `_state` parameter indicates whether to pause or unpause the validator.
    /// @param validator The address of the validator to change the pause state for.
    /// @param _state The desired pause state (true for paused, false for unpaused).
    function setPauseState(address validator, bool _state) external;

    /// @notice Sets the address of the fee manager.
    /// @dev This function allows the contract owner or admin to set the fee manager, who will be responsible for handling fee-related operations.
    /// @param _feeManager The address of the new fee manager.
    function setFeeManager(address _feeManager) external;

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
    function AddTotalStakedAmount(uint256 _amount) external;

    /// @notice Decreases the total staked amount by the specified amount.
    /// @dev This function is used to subtract a specified amount from the total staked amount across the system.
    /// @param _amount The amount to decrease the total staked amount by.
    function SubTotalStakedAmount(uint256 _amount) external;

    /// @notice Increases the total number of staked wallets.
    /// @dev This function is used to increase the number of wallets that have staked tokens in the system.
    function AddTotalStakedWallet() external;

    /// @notice Decreases the total number of staked wallets.
    /// @dev This function is used to decrease the number of wallets that have staked tokens in the system.
    function SubTotalStakedWallet() external;

    /// @notice Adds a new validator to the total validators list with the specified reward parameters.
    /// @dev This function is used to register a new validator to the system with the total reward parameters, including the start and end time for the reward period.
    /// @param _startTime The start time of the reward period for the new validator.
    /// @param _endTime The end time of the reward period for the new validator.
    /// @param _totalReward The total reward allocated to the new validator for the reward period.
    function AddTotalValidators(uint256 _startTime, uint256 _endTime, uint256 _totalReward) external;

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