// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

import "./interfaces/IValidator.sol";
import "./interfaces/IValidatorFactory.sol";
import "./interfaces/IGovernance.sol";

/**
 * @title Governance Contract
 * @dev This contract allows users to vote on proposals, including creating proposals, 
 * voting with veLrds balance, and distributing rewards to validators for specific boost proposals.
 * It also includes functionality to reset votes and manage vote rewards.
 */
contract Governance is IGovernance, Ownable2Step, ReentrancyGuard {
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
        uint256 boostStartTime;         // boostStartTime The start time for the distribution of the boost reward
        uint256 boostEndTime;           // boostEndTime The end time for the distribution of the boost reward
        FinalizationStatus status;      // status The current status of the boost proposal (Pending, Executed, Cancelled)
    }
    
    enum FinalizationStatus {
        Pending,                        // Pending The proposal is still in progress
        Executed,                       // Executed The proposal has been executed
        Cancelled                       // Cancelled The proposal has been cancelled
    }

    uint256 public PRECISION_FACTOR = 10**12;       // The precision factor for reward calculations
    uint256 public proposalCount;          // Counter for proposal IDs
    address public admin;                  // The address of the contract admin
    address public masterValidator;        // Address of the master validator contract
    address public factory;                // Address of the factory contract
    address public bank;                   // Address of the bank contract
    address public token;                  // Address of the LRDS

    mapping(uint256 => Proposal) public proposals;                                          // Mapping from proposal ID to Proposal struct
    mapping(uint256 => ValidatorBoostProposal) public boostProposals;                       // Mapping from proposal ID to ValidatorBoostProposal struct
    mapping(address => uint256) public userTotalVotes;                                      // Mapping from user address to their total votes
    mapping(uint256 => mapping(address => mapping(uint256 => uint256))) public userVotes;   // Mapping from proposal ID -> user -> choice -> weight
    mapping(uint256 => mapping(uint256 => uint256)) public optionVotes;                     // Mapping from proposal ID -> choice -> total votes

    mapping(uint256 => mapping(uint256 => address)) public proposalValidators;              // Mapping from proposal ID -> validator index -> validator address
    mapping(uint256 => uint256) public proposalValidatorCounts;                             // Mapping from proposal ID -> number of validators
    mapping(uint256 => bool) public isBoostVote;                                            // Mapping to check if a proposal is a boost proposal
    mapping(uint256 => uint256) public voteReward;                                          // Mapping of proposal ID to VoteReward
    mapping(uint256 => mapping(address => bool)) public votedStatus;                        // Mapping to record if a player has voted for a specific proposal
    mapping(uint256 => uint256) public proposalTotalVotes;                                  // Mapping tracks the total votes received by a proposal across all voters.
    mapping(uint256 => mapping(address => uint256)) public proposalUserTotalVotes;          // Mpping records the individual vote count for each user on each proposal.
    mapping(uint256 => mapping(address => bool)) public hasClaimedReward;                   // Mapping stores whether a user has already claimed their reward for a given proposal.

    // Modifier to ensure only the admin can access the function
    modifier onlyAdmin() {
        if (msg.sender != address(admin)) revert NotAdmin();
        _;
    }

    /**
     * @dev Constructor to initialize the Voter contract
     * @param _masterValidator The address of the master validator contract
     * @param _factory The address of the factory contract
     * @param _bank The address of the bank contract
     */
    constructor(address _masterValidator, address _factory, address _bank, address _token) Ownable(msg.sender) {
        masterValidator = _masterValidator;
        factory         = _factory;
        bank            = _bank;
        token           = _token;
        admin           = msg.sender;
    }

    /**
     * @dev Creates a new proposal for voting
     * @param _startTime The start time of the proposal voting period
     * @param _endTime The end time of the proposal voting period
     * @param _metadataURI URI for additional metadata associated with the proposal
     * @param _totalChoices The number of available choices for the proposal
     */
    function createPropose(uint256 _startTime, uint256 _endTime, string calldata _metadataURI, uint256 _totalChoices) external onlyAdmin {
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
     * @param _boostStartTime The start time for the distribution of the boost reward
     * @param _boostEndTime The end time for the distribution of the boost reward
     */
    function createBoostPropose(
        uint256 _startTime,
        uint256 _endTime,
        string calldata _metadataURI,
        uint256 _boostReward,
        uint256 _boostStartTime,
        uint256 _boostEndTime
    ) external onlyAdmin {
        if (_startTime >= _endTime|| block.timestamp > _startTime) revert WrongTime();
        if (_endTime >= _boostStartTime) revert WrongTime();
        if (_boostStartTime >= _boostEndTime) revert WrongBoostTime();
        if (_boostReward == 0) revert ZeroAmount();

        uint256 proposalId = proposalCount++;

        boostProposals[proposalId] = ValidatorBoostProposal({
            startTime:     _startTime,
            endTime:       _endTime,
            metadataURI:   _metadataURI,
            boostReward:   _boostReward,
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
    * @param _choiceId selected choice ID (for both regular and boost proposals)
    * @param _weight vote weights corresponding to each choice (for both regular and boost proposals)
    */
    function vote(uint256 _proposalId, uint256 _choiceId, uint256 _weight) external nonReentrant {
        if (_weight > 100 || _weight == 0) revert InvalidWeight();
        if (votedStatus[_proposalId][msg.sender] == true) revert UserIsVoted();

        // Declare the Proposal storage variable here after checking the type of proposal
        if (isBoostVote[_proposalId]) {
            // Boost proposal voting logic
            ValidatorBoostProposal storage boostProposal = boostProposals[_proposalId];

            // Common check for voting period
            _checkVotingPeriod(boostProposal.startTime, boostProposal.endTime, boostProposal.status);

            _vote(_proposalId, _choiceId, _weight, proposalValidatorCounts[_proposalId], true);
        } else {
            // Regular proposal voting logic
            Proposal storage proposal = proposals[_proposalId];
            
            // Common check for voting period
            _checkVotingPeriod(proposal.startTime, proposal.endTime, proposal.status);

            _vote(_proposalId, _choiceId, _weight, proposal.totalChoices, false);
        }
    }

    /// @inheritdoc IGovernance
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
    * @dev Allows users to claim their pending rewards for a specific proposal and automatically stake them in the MasterValidator contract.
    * This function transfers the pending reward tokens from the bank to the user and then stakes the reward amount in the MasterValidator contract.
    * After the reward is claimed and staked, the user's pending reward balance is cleared.
    * @param _proposalId The ID of the proposal for which the user wants to claim rewards.
    */
    function claimAndLock(uint256 _proposalId) external nonReentrant {

        // Ensure the proposal status is 'Executed' before claiming rewards
        if (proposals[_proposalId].status != FinalizationStatus.Executed) revert WrongStatus();

        // Ensure the user has voted on the proposal
        if (votedStatus[_proposalId][msg.sender] == false) revert UserIsNotVoted();

        // Check if the user has already claimed the reward for this proposal
        if (hasClaimedReward[_proposalId][msg.sender]) revert RewardAlreadyClaimed();

        uint256 rewardAmount = 0;

        // Calculate the reward based on the user's voting weight
        rewardAmount = proposalUserTotalVotes[_proposalId][msg.sender] * voteReward[_proposalId] / proposalTotalVotes[_proposalId];

        // Check if the user has any pending rewards to claim
        if (rewardAmount == 0) revert ZeroAmount();

        // Transfer the reward amount from the bank to the MasterValidator for staking
        IERC20(token).safeTransferFrom(bank, masterValidator, rewardAmount);

        // Stake the reward in the MasterValidator contract on behalf of the user
        IValidator(masterValidator).stakeFor(msg.sender, rewardAmount, true);

        // Mark the user as having claimed the reward for this proposal
        hasClaimedReward[_proposalId][msg.sender] = true;

        // Emit an event to record the claim and stake action
        emit RewardsClaimedAndLocked(msg.sender, _proposalId, rewardAmount);
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

    /**
    * @dev Handles voting logic for both regular and boost proposals.
    * @param _proposalId The ID of the proposal being voted on
    * @param _choiceId selected choice IDs
    * @param _weight vote weight corresponding to each choice
    * @param _totalChoices The total number of choices (0 for boost proposals)
    * @param _isBoostVote Boolean flag indicating if the proposal is a boost proposal
    */
    function _vote(
        uint256 _proposalId, 
        uint256 _choiceId, 
        uint256 _weight, 
        uint256 _totalChoices, 
        bool _isBoostVote
    ) internal {
        uint256 stakeWeight = 0;

        // Validate each choice for both regular and boost proposals
        _validateVoteChoice(_proposalId, _choiceId, _totalChoices, _isBoostVote);

        // Ensure the user's total vote weight does not exceed their available veLrds balance
        uint256 VeLrdsBalance = IValidator(masterValidator).veLrdsBalance(msg.sender);

        // Prevent zero available VeLrds to votes
        if (VeLrdsBalance == 0) revert ZeroVelrds();

        if (userTotalVotes[msg.sender] > VeLrdsBalance) revert ExceedsAvailableWeight();

        // Accumulate the total weight of the user's vote
        stakeWeight = ((VeLrdsBalance - userTotalVotes[msg.sender]) * _weight * PRECISION_FACTOR) / 100 / PRECISION_FACTOR;  

        // Update user votes for the selected option
        userVotes[_proposalId][msg.sender][_choiceId] = stakeWeight;

        // Update total votes for the selected option
        optionVotes[_proposalId][_choiceId] += stakeWeight;

        // Update the user's total votes
        userTotalVotes[msg.sender] += stakeWeight;

        proposalTotalVotes[_proposalId] += stakeWeight;
        
        proposalUserTotalVotes[_proposalId][msg.sender] = stakeWeight;
         
        // Record the voter for the proposal
        // _recordVoter(_proposalId, msg.sender);

        // Record the player's vote
        votedStatus[_proposalId][msg.sender] = true;

        emit Voted(msg.sender, _proposalId, _choiceId, stakeWeight);
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
    * @param _startTime The start time of the voting period
    * @param _endTime The end time of the voting period
    * @param _status The status of the voting period
    */
    function _checkVotingPeriod(uint256 _startTime, uint256 _endTime, FinalizationStatus _status) internal view {
        if (block.timestamp < _startTime || block.timestamp > _endTime) revert VotingNotOpen();
        if (_status != FinalizationStatus.Pending) revert WrongStatus();
    }

    /*//////////////////////////////////////////////////////////////
                               ADMIN
    //////////////////////////////////////////////////////////////*/

    /**
    * @dev Executes the reward distribution for a given proposal based on the vote weight.
    * This function is called by the owner to calculate rewards for voters after the voting period ends.
    * It no longer transfers the rewards immediately but records them for each voter.
    * @param _proposalId The ID of the proposal whose vote rewards are being calculated.
    */
    function executeVoteRewardProposal(uint256 _proposalId) external onlyAdmin {

        bool isBoostProposal = isBoostVote[_proposalId];  // Check if the proposal is a boost proposal
        uint256 totalReward  = voteReward[_proposalId];  // Total reward to distribute

        // Ensure that the reward amount is greater than 0
        if (totalReward == 0) revert ZeroAmount();

        // Check if the proposal is a boost proposal
        if (isBoostProposal) {
            // For boost proposals, retrieve the reward details and check voting period
            ValidatorBoostProposal storage boostProposal = boostProposals[_proposalId];
            // Check the proposal status
            _checkExecuteReward(boostProposal.endTime, boostProposal.status);

            // Update the proposal status to Executed
            boostProposal.status = FinalizationStatus.Executed;
        } else {
            // For regular proposals, retrieve the reward details and check voting period
            Proposal storage proposal = proposals[_proposalId];
            // Check the proposal status
            _checkExecuteReward(proposal.endTime, proposal.status);
            
            // Update the proposal status to Executed
            proposal.status = FinalizationStatus.Executed;
        }
        
        // Emit event for reward distribution execution
        emit 
        RewardDistributionExecuted(_proposalId, totalReward, block.timestamp);
    }

    /**
    * @dev Sets the reward token and reward amount for a given proposal.
    * This function allows the contract owner to configure the reward settings for a specific proposal.
    * @param _proposalId The ID of the proposal for which the reward is being set.
    * @param _rewardAmount The total reward amount allocated for the proposal.
    */
    function setVoteReward(uint256 _proposalId, uint256 _rewardAmount) external onlyAdmin {
        
        // Check that the reward amount is greater than zero
        if (_rewardAmount == 0) revert ZeroAmount();

        // Set the reward token address and reward amount for the proposal
        voteReward[_proposalId] = _rewardAmount;
    }

    /**
    * @dev Cancels a proposal (either regular or boost proposal) by marking it as cancelled.
    * This function checks if the proposal is a boost proposal using the `isBoostVote` mapping.
    * @param _proposalId The ID of the proposal to be cancelled.
    */
    function cancelProposal(uint256 _proposalId) external onlyAdmin {
        // Check if it is a boost proposal
        if (isBoostVote[_proposalId]) {
            // Handling for boost proposal
            ValidatorBoostProposal storage boostProposal = boostProposals[_proposalId];

            // Ensure the proposal is still pending
            if (boostProposal.status != FinalizationStatus.Pending) revert WrongStatus();

            // Ensure that the proposal has no staked votes before canceling
            if (proposalTotalVotes[_proposalId] > 0) revert ProposalHasStakedVotes();

            // Mark the boost proposal as cancelled
            boostProposal.status = FinalizationStatus.Cancelled;
            emit BoostProposalCancelled(_proposalId);

        } else {
            // Handling for regular proposal
            Proposal storage proposal = proposals[_proposalId];

            // Check if the proposal is in Pending status before proceeding
            if (proposal.status != FinalizationStatus.Pending) revert WrongStatus();

            // Ensure that the proposal has no staked votes before canceling
            if (proposalTotalVotes[_proposalId] > 0) revert ProposalHasStakedVotes();

            // Mark the proposal as cancelled
            proposal.status = FinalizationStatus.Cancelled;
            emit ProposalCancelled(_proposalId);
        }
    }

    /**
     * @dev Distributes the boost rewards to the validators based on their votes
     * @param proposalId The ID of the boost proposal
     */
    function addBoostReward(uint256 proposalId) external onlyAdmin {
        ValidatorBoostProposal storage boostProposal = boostProposals[proposalId];

        // Check if the current time is within the reward distribution period
        if (block.timestamp < boostProposal.endTime || block.timestamp > boostProposal.boostStartTime) {
            revert RewardDistributionNotAllowed();
        }

        uint256 totalBoostReward = boostProposal.boostReward;
        if (totalBoostReward == 0) revert RewardIsZero();

        uint256 totalVotes = 0;

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
                IERC20(token).safeTransferFrom(bank, validator, validatorBoostReward);
                IValidator(validator).addBoostReward(boostProposal.boostStartTime, boostProposal.boostEndTime, validatorBoostReward);
            }

            // Record the transfer event
            emit BoostRewardTransferred(proposalId, validator, validatorBoostReward);
        }

        // Reset the boost reward to avoid double distribution
        boostProposal.boostReward = 0;

        emit BoostRewardDistributed(proposalId, totalBoostReward);
    }
    
    /**
    * @dev Checks if the reward execution conditions are met.
    * @param _endTime The end time after which the reward can be executed.
    * @param _status The current finalization status that must be checked.
    */
    function _checkExecuteReward(uint256 _endTime, FinalizationStatus _status) internal view {
        if (block.timestamp <= _endTime) revert TimeIsNotUp();
        if (_status != FinalizationStatus.Pending) revert WrongStatus();
    }

    /*//////////////////////////////////////////////////////////////
                               OWNER
    //////////////////////////////////////////////////////////////*/
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
    * @dev Sets the address of the new admin.
    * This function can only be called by the current owner of the contract.
    * Once executed, the specified address will be granted admin privileges.
    * 
    * @param _newAdmin The address of the new admin. The provided address will be set as the admin of the contract.
    */
    function setAdmin(address _newAdmin) external onlyOwner {
        admin = _newAdmin;
    }
}