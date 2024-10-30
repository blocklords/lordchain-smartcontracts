// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IValidatorFactory {
    event SetFeeManager(address feeManager);
    event SetPauser(address pauser);
    event SetPauseState(bool state);
    event SetVoter(address voter);
    event SetDepositCustomFee(address indexed validator, uint256 fee);
    event SetClaimCustomFee(address indexed validator, uint256 fee);
    event ValidatorCreated(address indexed token, address indexed owner, address validator, uint256 validatorLength);

    error FeeTooHigh();
    error InvalidValidator();
    error NotFeeManager();
    error NotPauser();
    error NotVoter();
    error PoolAlreadyExists();
    error ZeroFee();
    error ZeroAddress();

    /// @notice returns the number of validators created from this factory
    function allValidatorsLength() external view returns (uint256);

    /// @notice Return address of validator created by this factory
    /// @param token .
    /// @param owner .
    function getValidator(address token, address owner) external view returns (address);

    /// @notice Is a valid validator created by this factory.
    /// @param validator.
    function isValidatorl(address validator) external view returns (bool);

    /// @dev Only called once to set to Voter.sol - Voter does not have a function
    ///      to call this contract method, so once set it's immutable.
    ///      This also follows convention of setVoterAndDistributor() in VotingEscrow.sol
    /// @param _voter .
    function setVoter(address _voter) external;

    function setPauser(address _pauser) external;

    function setPauseState(bool _state) external;

    function setFeeManager(address _feeManager) external;

    /// @notice Set default fee for stable and volatile pools.
    /// @dev Throws if higher than maximum fee.
    ///      Throws if fee is zero.
    /// @param _type Stable or volatile pool.
    /// @param _fee .
    function setFee(bool _type, uint256 _fee) external;

    /// @notice Set overriding fee for a validator from the default
    /// @dev A custom fee of zero means the default fee will be used.
    function setDepositCustomFee(address _validator, uint256 _fee) external;

    /// @notice Set overriding fee for a validator from the default
    /// @dev A custom fee of zero means the default fee will be used.
    function setClaimCustomFee(address _validator, uint256 _fee) external;

    /// @notice Create a validator given token and owner
    /// @dev token order does not matter
    /// @param token .
    /// @param owner .
    function createValidator(address token, address owner) external returns (address validator);

    function isPaused() external view returns (bool);

    function voter() external view returns (address);

    function implementation() external view returns (address);
}