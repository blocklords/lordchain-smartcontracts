// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IValidatorFactory {
    event SetFeeManager(address feeManager);
    event SetPauser(address pauser);
    event SetPauseState(address validator, bool state);
    event SetVoter(address voter);
    event SetDepositCustomFee(address indexed validator, uint256 fee);
    event SetClaimCustomFee(address indexed validator, uint256 fee);
    event ValidatorCreated(address indexed token, address indexed owner, address validator, uint256 validatorLength);

    error InvalidValidator();
    error NotFeeManager();
    error NotPauser();
    error NotVoter();
    error NotAdmin();
    error PoolAlreadyExists();
    error ZeroAddress();
    error NotEnoughAmount();
    error NotEnoughWallet();
    error NotRegisteredValidator();

    /// @notice returns the number of validators created from this factory
    function allValidatorsLength() external view returns (uint256);

    /// @notice Return address of validator created by this factory
    /// @param token .
    /// @param owner .
    /// @param validatorId .
    function getValidator(address token, address owner, uint256 validatorId) external view returns (address);

    /// @notice Is a valid validator created by this factory.
    /// @param validator.
    function isValidatorl(address validator) external view returns (bool);

    /// @dev Only called once to set to Voter.sol - Voter does not have a function
    ///      to call this contract method, so once set it's immutable.
    ///      This also follows convention of setVoterAndDistributor() in VotingEscrow.sol
    /// @param _voter .
    function setVoter(address _voter) external;

    function setPauser(address _pauser) external;

    function setPauseState(address validator, bool _state) external;

    function setFeeManager(address _feeManager) external;

    // /// @notice Set overriding fee for a validator from the default
    // /// @dev A custom fee of zero means the default fee will be used.
    // function setDepositCustomFee(address _validator, uint256 _fee) external;

    // /// @notice Set overriding fee for a validator from the default
    // /// @dev A custom fee of zero means the default fee will be used.
    // function setClaimCustomFee(address _validator, uint256 _fee) external;

    /// @notice Create a validator given token and owner
    /// @dev token order does not matter
    /// @param _token .
    /// @param _owner .
    /// @param _isClaimed .
    /// @param _quality .
    function createValidator(address _token, address _owner, bool _isClaimed, uint256 _quality) external returns (address validator);

    // function isPaused() external view returns (bool);

    function voter() external view returns (address);

    function implementation() external view returns (address);

    function AddTotalStakedAmount(uint256 _amount) external;

    function SubTotalStakedAmount(uint256 _amount) external;
    
    function AddTotalStakedWallet() external;

    function SubTotalStakedWallet() external;

    function AddTotalValidators(uint256 _startTime, uint256 _endTime, uint256 _totalReward) external;

    function minAmountForQuality(uint256) external returns (uint256);
}