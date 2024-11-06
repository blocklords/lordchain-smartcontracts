// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IValidator.sol";
import "./interfaces/IValidatorFactory.sol";
import "./interfaces/IVoter.sol";

/**
 * @title Voter Contract
 * @dev This contract allows users to vote on proposals, including creating proposals, 
 * voting with veLrds balance, and distributing rewards to validators for specific boost proposals.
 * It also includes functionality to reset votes and manage vote rewards.
 */
contract Voter is IVoter, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Proposal {
        uint256 startTime;              // startTime The start time of the proposal voting period
        uint256 endTime;                // endTime The end time of the proposal voting period
        string metadataURI;             // metadataURI URI for additional metadata associated with the proposal
        uint256 totalChoices;           // totalChoices The number of available choices for the proposal
        FinalizationStatus status;      // status The current status of the proposal (Pending, Executed, Cancelled)
    }
    
    struct ValidatorBoostProposal {
        uint256 startTime;              // startTime The start time of the boost proposal
        uint256 endTime;                // endTime The end time of the boost proposal
        string metadataURI;             // metadataURI URI for additional metadata associated with the boost proposal
        uint256 boostReward;            // boostReward The total boost reward to be distributed to validators
        address rewardToken;            // rewardToken The token used for the reward
        uint256 boostStartTime;         // boostStartTime The start time for the distribution of the boost reward
        uint256 boostEndTime;           // boostEndTime The end time for the distribution of the boost reward
        FinalizationStatus status;      // status The current status of the boost proposal (Pending, Executed, Cancelled)
    }
    
    enum FinalizationStatus {
        Pending,                        // Pending The proposal is still in progress
        Executed,                       // Executed The proposal has been executed
        Cancelled                       // Cancelled The proposal has been cancelled
    }

    uint256 public proposalCount;          // Counter for proposal IDs
    address public masterValidator;        // Address of the master validator contract
    address public factory;                // Address of the factory contract
    address public bank;                   // Address of the bank contract

    mapping(uint256 => Proposal) public proposals;                                          // Mapping from proposal ID to Proposal struct
    mapping(uint256 => ValidatorBoostProposal) public boostProposals;                       // Mapping from proposal ID to ValidatorBoostProposal struct
    mapping(address => uint256) public userTotalVotes;                                      // Mapping from user address to their total votes
    mapping(uint256 => mapping(address => mapping(uint256 => uint256))) public userVotes;   // Mapping from proposal ID -> user -> choice -> weight
    mapping(uint256 => mapping(uint256 => uint256)) public optionVotes;                     // Mapping from proposal ID -> choice -> total votes

    mapping(uint256 => mapping(uint256 => address)) public proposalValidators;              // Mapping from proposal ID -> validator index -> validator address
    mapping(uint256 => uint256) public proposalValidatorCounts;                             // Mapping from proposal ID -> number of validators

    /**
     * @dev Constructor to initialize the Voter contract
     * @param _masterValidator The address of the master validator contract
     * @param _factory The address of the factory contract
     * @param _bank The address of the bank contract
     */
    constructor(address _masterValidator, address _factory, address _bank) Ownable(msg.sender) {
        masterValidator = _masterValidator;
        factory = _factory;
        bank = _bank;
    }

    /**
     * @dev Creates a new proposal for voting
     * @param _startTime The start time of the proposal voting period
     * @param _endTime The end time of the proposal voting period
     * @param _metadataURI URI for additional metadata associated with the proposal
     * @param _totalChoices The number of available choices for the proposal
     */
    function createPropose(uint256 _startTime, uint256 _endTime, string calldata _metadataURI, uint256 _totalChoices) external onlyOwner {
        if(_startTime >=_endTime || block.timestamp > _startTime) revert WrongTime();
        
        uint256 proposalId = proposalCount++;
        
        proposals[proposalId] = Proposal({
            startTime:     _startTime,
            endTime:       _endTime,
            metadataURI:   _metadataURI,
            totalChoices:  _totalChoices,
            status:        FinalizationStatus.Pending
        });

        emit ProposalCreated(proposalId, _startTime, _endTime, _metadataURI, _totalChoices);
    }
    
    /**
     * @dev Allows users to vote on a proposal
     * @param _proposalId The ID of the proposal being voted on
     * @param _choiceIds Array of selected choice IDs
     * @param _weights Array of vote weights corresponding to each choice
     */
    function vote(uint256 _proposalId, uint256[] calldata _choiceIds, uint256[] calldata _weights) external nonReentrant {
        if (_choiceIds.length != _weights.length) revert UnequalLengths();
    
        // Check if the voting period is active
        Proposal storage proposal = proposals[_proposalId];
        if (block.timestamp < proposal.startTime || block.timestamp > proposal.endTime) revert VotingNotOpen();

        // Retrieve veLrds balance from masterValidator contract
        uint256 availableVeLrds = IValidator(masterValidator).veLrdsBalance(msg.sender);
        if (availableVeLrds <=0 ) revert NoVeLRDS();
        
        uint256 totalWeight = 0;
        for (uint256 i = 0; i < _choiceIds.length; i++) {
            // Prevent voting for invalid choices
            if (_choiceIds[i] >= proposal.totalChoices) revert NoSuchOption(); 

            uint256 weight = _weights[i];
            // Prevent zero weight votes
            if(weight <= 0) revert WrongValue();

            // Update user votes for the selected option
            userVotes[_proposalId][msg.sender][_choiceIds[i]] += weight;

            // Update total votes for the selected option
            optionVotes[_proposalId][_choiceIds[i]] += weight;
            
            // Accumulate the total weight of the user's vote
            totalWeight += weight;
        }

        // Ensure the user's total vote weight does not exceed their available veLrds balance
        if ((totalWeight + userTotalVotes[msg.sender]) > availableVeLrds) revert ExceedsAvailableWeight();

        // Update the user's total votes
        userTotalVotes[msg.sender] += totalWeight;

        emit Voted(msg.sender, _proposalId, _choiceIds, _weights);

    }

    /**
     * @dev Creates a new boost proposal for validators
     * @param _startTime The start time of the boost proposal
     * @param _endTime The end time of the boost proposal
     * @param _metadataURI URI for additional metadata associated with the boost proposal
     * @param _boostReward The total boost reward to be distributed to validators
     * @param _rewardToken The token used for the reward
     * @param _boostStartTime The start time for the distribution of the boost reward
     * @param _boostEndTime The end time for the distribution of the boost reward
     */
    function createBoostPropose(
        uint256 _startTime,
        uint256 _endTime,
        string calldata _metadataURI,
        uint256 _boostReward,
        address _rewardToken,
        uint256 _boostStartTime,
        uint256 _boostEndTime
    ) external onlyOwner {
        if (_startTime >= _endTime|| block.timestamp > _startTime) revert WrongTime();
        if (_endTime >= _boostStartTime) revert WrongTime();
        if (_boostStartTime >= _boostEndTime) revert WrongBoostTime();
        if (_boostReward <= 0) revert WrongValue();

        uint256 proposalId = ++proposalCount;

        boostProposals[proposalId] = ValidatorBoostProposal({
            startTime:     _startTime,
            endTime:       _endTime,
            metadataURI:   _metadataURI,
            boostReward:   _boostReward,
            rewardToken:   _rewardToken,
            boostStartTime:_boostStartTime,
            boostEndTime:  _boostEndTime,
            status:        FinalizationStatus.Pending
        });

        address[] memory _validators = IValidatorFactory(factory).getValidators();
        
        uint256 validIndex = 0;  // Counter for valid validators
        for (uint256 i = 0; i < _validators.length; i++) {
            IValidator validator = IValidator(_validators[i]);
            
            // Check if the validator has been claimed
            if (validator.isClaimed()) {
                proposalValidators[proposalId][validIndex] = _validators[i];
                validIndex++;
            }
        }
        
        proposalValidatorCounts[proposalId] = validIndex;
        emit BoostProposalCreated(proposalId, _startTime, _endTime, _boostReward, _boostStartTime, _boostEndTime, _validators.length, _validators);
    }

    /**
     * @dev Distributes the boost rewards to the validators based on their votes
     * @param proposalId The ID of the boost proposal
     */
    function addBoostReward(uint256 proposalId) external onlyOwner {
        ValidatorBoostProposal storage boostProposal = boostProposals[proposalId];

        // Check if the current time is within the reward distribution period
        if (block.timestamp < boostProposal.endTime || block.timestamp > boostProposal.boostStartTime) {
            revert RewardDistributionNotAllowed();
        }

        uint256 totalBoostReward = boostProposal.boostReward;
        uint256 totalVotes;

        // Calculate the total votes for the proposal to determine the distribution proportion
        for (uint256 i = 0; i < proposalValidatorCounts[proposalId]; i++) {
            totalVotes += optionVotes[proposalId][i];
        }

        // Ensure there are votes to distribute rewards
        if (totalVotes == 0) revert NoVotes();

        // Distribute the rewards to the validators
        for (uint256 i = 0; i < proposalValidatorCounts[proposalId]; i++) {
            address validator = proposalValidators[proposalId][i];
            uint256 validatorVotes = optionVotes[proposalId][i];

            // Calculate the validator's share of the boost reward
            uint256 validatorBoostReward = (validatorVotes * totalBoostReward) / totalVotes;
            if (validatorBoostReward > 0) {
                IERC20(boostProposal.rewardToken).safeTransferFrom(bank, validator, validatorBoostReward);
                IValidator(validator).addBoostReward(boostProposal.boostStartTime, boostProposal.boostEndTime, validatorBoostReward);
            }

            // Record the transfer event
            emit BoostRewardTransferred(proposalId, validator, validatorBoostReward);
        }

        // Reset the boost reward to avoid double distribution
        boostProposal.boostReward = 0;   
        
        // Change proposal status to 'Cancelled' after reward distribution is completed
        boostProposal.status = FinalizationStatus.Cancelled;

        emit BoostRewardDistributed(proposalId, totalBoostReward);
    }

    /// @inheritdoc IVoter
    function resetVotes(address _user) external {
        if (msg.sender != masterValidator) revert NotValidator();
        userTotalVotes[_user] = 0;
    }

    /**
    * @dev Retrieves the number of votes cast by a user for all available choices in a specific proposal.
    * @param _proposalId The ID of the proposal being queried.
    * @param _user The address of the user whose votes are being fetched.
    * @return votes An array containing the number of votes the user has cast for each available choice in the proposal.
    */
    function getUserVotesForAllChoices(uint256 _proposalId,  address _user) external view returns (uint256[] memory) {
        uint256 totalChoices = proposals[_proposalId].totalChoices;
        uint256[] memory votes = new uint256[](totalChoices);

        for (uint256 i = 0; i < totalChoices; i++) {
            votes[i] = userVotes[_proposalId][_user][i];
        }

        return votes;
    }

    /**
    * @dev Retrieves the total number of votes cast for each available choice in a specific proposal.
    * @param _proposalId The ID of the proposal being queried.
    * @return votes An array containing the total number of votes each choice has received in the proposal.
    */
    function getProposalOptionVotes(uint256 _proposalId) external view returns (uint256[] memory) {
        uint256 totalChoices = proposals[_proposalId].totalChoices;
        uint256[] memory votes = new uint256[](totalChoices);

        for (uint256 i = 0; i < totalChoices; i++) {
            votes[i] = optionVotes[_proposalId][i];
        }

        return votes;
    }

    /**
     * @dev Cancels a proposal by marking it as cancelled
     * @param _proposalId The ID of the proposal to be finalized
     */
    function cancelProposal(uint256 _proposalId) external onlyOwner {
        Proposal storage proposal = proposals[_proposalId];
        if (proposal.status != FinalizationStatus.Pending) revert WrongStatus();
        
        proposal.status = FinalizationStatus.Cancelled;
        emit ProposalCancelled(_proposalId);
    }

    /**
     * @dev Cancesl a boost proposal by marking it as cancelled
     * @param _proposalId The ID of the boost proposal to be finalized
     */
    function cancelBoostProposal(uint256 _proposalId) external onlyOwner {
        ValidatorBoostProposal storage boostProposal = boostProposals[_proposalId];
        if (boostProposal.status != FinalizationStatus.Pending) revert WrongStatus();
        
        boostProposal.status = FinalizationStatus.Cancelled;
        emit BoostProposalCancelled(_proposalId);
    }
}