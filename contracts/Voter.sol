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

    struct VoteReward {
        address rewardToken;  // The address of the reward token (ERC20 token)
        uint256 rewardAmount; // The total reward amount allocated for the proposal
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
    mapping(uint256 => bool) public isBoostVote;                                            // Mapping to check if a proposal is a boost proposal
    mapping(uint256 => VoteReward) public voteRewards;                                      // Mapping of proposal ID to VoteReward
    mapping(uint256 => address[]) public proposalVoters;                                    // Records all the voters' addresses for each proposal

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
        isBoostVote[proposalId] = false;

        emit ProposalCreated(proposalId, _startTime, _endTime, _metadataURI, _totalChoices);
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
        isBoostVote[proposalId] = true;

        emit BoostProposalCreated(proposalId, _startTime, _endTime, _boostReward, _boostStartTime, _boostEndTime, _validators.length, _validators);
    }

    /**
    * @dev Main vote method, handles both regular and boost proposals.
    * @param _proposalId The ID of the proposal being voted on
    * @param _choiceIds Array of selected choice IDs (for both regular and boost proposals)
    * @param _weights Array of vote weights corresponding to each choice (for both regular and boost proposals)
    */
    function vote(uint256 _proposalId, uint256[] calldata _choiceIds, uint256[] calldata _weights) external nonReentrant {
        // Check if choiceIds and weights lengths match
        if (_choiceIds.length != _weights.length) revert UnequalLengths();


        // Declare the Proposal storage variable here after checking the type of proposal
        if (isBoostVote[_proposalId]) {
            // Boost proposal voting logic
            ValidatorBoostProposal storage boostProposal = boostProposals[_proposalId];

            // Common check for voting period
            _checkVotingPeriod(boostProposal.startTime, boostProposal.endTime);

            _vote(_proposalId, _choiceIds, _weights, proposalValidatorCounts[_proposalId], true);
        } else {
            // Regular proposal voting logic
            Proposal storage proposal = proposals[_proposalId];
            
            // Common check for voting period
            _checkVotingPeriod(proposal.startTime, proposal.endTime);

            _vote(_proposalId, _choiceIds, _weights, proposal.totalChoices, false);
        }
    }

    /**
    * @dev Handles voting logic for both regular and boost proposals.
    * @param _proposalId The ID of the proposal being voted on
    * @param _choiceIds Array of selected choice IDs
    * @param _weights Array of vote weights corresponding to each choice
    * @param _totalChoices The total number of choices (0 for boost proposals)
    * @param _isBoostVote Boolean flag indicating if the proposal is a boost proposal
    */
    function _vote(
        uint256 _proposalId, 
        uint256[] calldata _choiceIds, 
        uint256[] calldata _weights, 
        uint256 _totalChoices, 
        bool _isBoostVote
    ) internal {
        uint256 totalWeight = 0;

        for (uint256 i = 0; i < _choiceIds.length; i++) {
            // Validate each choice for both regular and boost proposals
            _validateVoteChoice(_proposalId, _choiceIds[i], _totalChoices, _isBoostVote);

            uint256 weight = _weights[i];
            // Prevent zero weight votes
            if (weight <= 0) revert WrongValue();

            // Update user votes for the selected option
            userVotes[_proposalId][msg.sender][_choiceIds[i]] += weight;

            // Update total votes for the selected option
            optionVotes[_proposalId][_choiceIds[i]] += weight;

            // Accumulate the total weight of the user's vote
            totalWeight += weight;
        }

        // Ensure the user's total vote weight does not exceed their available veLrds balance
        uint256 availableVeLrds = IValidator(masterValidator).veLrdsBalance(msg.sender);
        if ((totalWeight + userTotalVotes[msg.sender]) > availableVeLrds) revert ExceedsAvailableWeight();

        // Update the user's total votes
        userTotalVotes[msg.sender] += totalWeight;
         
        // Record the voter for the proposal
        _recordVoter(_proposalId, msg.sender);

        emit Voted(msg.sender, _proposalId, _choiceIds, _weights);
    }

    /**
    * @dev Records the voter for a specific proposal.
    * Checks if the voter has already voted and adds them to the list of voters if not.
    * @param _proposalId The ID of the proposal the user is voting on.
    * @param voter The address of the user who is voting.
    */
    function _recordVoter(uint256 _proposalId, address voter) internal {
        bool alreadyVoted = false;
        
        // Check if the user has already voted
        for (uint256 i = 0; i < proposalVoters[_proposalId].length; i++) {
            if (proposalVoters[_proposalId][i] == voter) {
                alreadyVoted = true;
                break;
            }
        }
        
        // If the user hasn't voted yet, add their address to the list of voters
        if (!alreadyVoted) {
            proposalVoters[_proposalId].push(voter);
        }
    }

    /**
    * @dev Validates the vote choice based on proposal type
    * @param _proposalId The ID of the proposal being voted on
    * @param _choiceId The selected choice ID
    * @param _totalChoices The total number of choices (0 for boost proposals)
    * @param _isBoostVote Boolean flag indicating if the proposal is a boost proposal
    */
    function _validateVoteChoice(uint256 _proposalId, uint256 _choiceId, uint256 _totalChoices, bool _isBoostVote) internal view {
        if (_isBoostVote) {
            // Boost proposal: check if the choice corresponds to a valid validator
            if (proposalValidators[_proposalId][_choiceId] == address(0)) revert NoSuchOption();
        } else {
            // Regular proposal: check if the choice is valid
            if (_choiceId >= _totalChoices) revert NoSuchOption();
        }
    }

    /**
    * @dev Checks if the voting period is active
    * @param startTime The start time of the voting period
    * @param endTime The end time of the voting period
    */
    function _checkVotingPeriod(uint256 startTime, uint256 endTime) internal view {
        if (block.timestamp < startTime || block.timestamp > endTime) revert VotingNotOpen();
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
    * @param _proposalId The ID of the proposal to be cancelled
    */
    function cancelProposal(uint256 _proposalId) external onlyOwner {
        Proposal storage proposal = proposals[_proposalId];

        // Check if the proposal is in Pending status before proceeding
        if (proposal.status != FinalizationStatus.Pending) revert WrongStatus();

        // Ensure that the proposal has no staked votes before canceling
        bool hasStakedVotes = false;

        // Check if there are any votes in any of the options for the proposal
        for (uint256 i = 0; i < proposal.totalChoices; i++) {
            if (optionVotes[_proposalId][i] > 0) {
                hasStakedVotes = true;
                break;
            }
        }

        // If there are staked votes, revert with an error
        if (hasStakedVotes) revert ProposalHasStakedVotes();

        // Mark the proposal as cancelled
        proposal.status = FinalizationStatus.Cancelled;
        emit ProposalCancelled(_proposalId);
    }

    /**
    * @dev Cancels a boost proposal by marking it as cancelled
    * @param _proposalId The ID of the boost proposal to be cancelled
    */
    function cancelBoostProposal(uint256 _proposalId) external onlyOwner {
        ValidatorBoostProposal storage boostProposal = boostProposals[_proposalId];

        // Ensure the proposal is still pending
        if (boostProposal.status != FinalizationStatus.Pending) revert WrongStatus();

        // Check if the boost proposal has votes before canceling
        bool hasVotes = false;

        // Loop through all possible choices to check if any of them have votes
        for (uint256 i = 0; i < proposalValidatorCounts[_proposalId]; i++) {
            if (optionVotes[_proposalId][i] > 0) {
                hasVotes = true;
                break;
            }
        }

        // If there are votes, revert the cancellation
        if (hasVotes) revert ProposalHasStakedVotes();

        // Mark the boost proposal as cancelled
        boostProposal.status = FinalizationStatus.Cancelled;
        emit BoostProposalCancelled(_proposalId);
    }

    /**
    * @dev Sets the reward token and reward amount for a given proposal.
    * This function allows the contract owner to configure the reward settings for a specific proposal.
    * @param _proposalId The ID of the proposal for which the reward is being set.
    * @param _rewardToken The address of the reward token (ERC20 token) that will be used to reward voters.
    * @param _rewardAmount The total reward amount allocated for the proposal.
    */
    function setVoteReward(uint256 _proposalId, address _rewardToken, uint256 _rewardAmount) external onlyOwner {
        // Check that the reward token address is valid (not zero address)
        if (_rewardToken == address(0)) revert ZeroAddress();
        
        // Check that the reward amount is greater than zero
        if (_rewardAmount <= 0) revert WrongValue();

        // Set the reward token address and reward amount for the proposal
        voteRewards[_proposalId] = VoteReward({
            rewardToken : _rewardToken,
            rewardAmount: _rewardAmount
        });
    }

    /**
    * @dev Executes the reward distribution for a given proposal based on the vote weight.
    * This function is called by the owner to distribute rewards to voters after the voting period ends.
    * @param _proposalId The ID of the proposal whose vote rewards are being distributed.
    */
    function executeVoteRewardProposal(uint256 _proposalId) external onlyOwner {
        // Retrieve the reward details for the proposal
        VoteReward storage reward = voteRewards[_proposalId];

        uint256 totalVotes   = 0;  // Total votes cast in the proposal
        bool isBoostProposal = isBoostVote[_proposalId];  // Check if the proposal is a boost proposal
        uint256 totalReward  = reward.rewardAmount;  // Total reward to distribute
        address rewardToken  = reward.rewardToken;  // The token being distributed as a reward

        // Ensure that the reward amount is greater than 0
        if (totalReward <= 0) revert ZeroAmount();

        // Check the proposal status
        if (proposals[_proposalId].status != FinalizationStatus.Pending) {
            revert("Proposal is not in Pending status");
        }

        // Check if the proposal is a boost proposal
        if (isBoostProposal) {
            // For boost proposals, retrieve the reward details and check voting period
            ValidatorBoostProposal storage boostProposal = boostProposals[_proposalId];
            _checkVotingPeriod(boostProposal.startTime, boostProposal.endTime);

            // Sum the votes from all validators for the boost proposal
            for (uint256 i = 0; i < proposalValidatorCounts[_proposalId]; i++) {
                totalVotes += optionVotes[_proposalId][i];
            }

        } else {
            // For regular proposals, retrieve the reward details and check voting period
            Proposal storage proposal = proposals[_proposalId];
            _checkVotingPeriod(proposal.startTime, proposal.endTime);

            // Sum the votes from all choices for the regular proposal
            for (uint256 i = 0; i < proposal.totalChoices; i++) {
                totalVotes += optionVotes[_proposalId][i];
            }
        }

        // Ensure there were votes cast in the proposal
        if (totalVotes <= 0) revert ZeroAmount();

        // Retrieve the list of voters for the proposal
        address[] memory voters = proposalVoters[_proposalId];

        // Loop through each voter to calculate their reward
        for (uint256 i = 0; i < voters.length; i++) {
            address voter = voters[i];
            uint256 totalVoterWeight = 0;

            // Accumulate the voter's total weight across all options/validators
            if (isBoostProposal) {
                // For boost proposals, sum the user's votes across all validators
                for (uint256 j = 0; j < proposalValidatorCounts[_proposalId]; j++) {
                    totalVoterWeight += userVotes[_proposalId][voter][j];
                }
            } else {
                // For regular proposals, sum the user's votes across all choices
                for (uint256 j = 0; j < proposals[_proposalId].totalChoices; j++) {
                    totalVoterWeight += userVotes[_proposalId][voter][j];
                }
            }

            // Calculate the reward for the current voter based on their vote weight
            uint256 rewardForVoter = (totalVoterWeight * totalReward) / totalVotes;

            // Transfer the calculated reward to the voter
            if (rewardForVoter > 0) {
                IERC20(rewardToken).safeTransferFrom(bank, voter, rewardForVoter);
            }
        }

        // Clear the reward data for the proposal after the reward distribution is complete
        delete voteRewards[_proposalId];

        // Update the proposal status to Executed
        proposals[_proposalId].status = FinalizationStatus.Executed;
    }

}