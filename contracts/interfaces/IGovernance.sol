// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IGovernance {

    error InvalidWeight();
    error VotingNotOpen();
    error WrongTime();
    error NoVeLRDS();
    error NotValidator();
    error NoSuchOption();
    error ExceedsAvailableWeight();
    error WrongBoostTime();
    error RewardDistributionNotAllowed();
    error NoVotes();
    error WrongStatus();
    error ZeroAddress();
    error ZeroAmount();
    error ProposalHasStakedVotes();
    error UserIsVoted();
    error UserIsNotVoted();
    error RewardAlreadyClaimed();
    error NotAdmin();
    error TimeIsNotUp();
    error RewardIsZero();
    error ZeroVelrds();
    error RewardAlreadyDistributed();
    error InvalidCycle();
    error CycleTooLarge();
    
    event ProposalCreated(uint256 indexed proposalId, uint256 startTime, uint256 endTime, string metadataURI, uint256 totalChoices);
    event Voted(address indexed sender, uint256 proposalId, uint256 choiceIds, uint256 weights);
    event BoostProposalCreated(uint256 indexed proposalId, uint256 startTime, uint256 endTime, uint256 _boostReward, uint256 _boostStartTime, uint256 _boostEndTime, uint256 validatorsNum, address[] indexed validators);
    event BoostRewardDistributed(uint256 indexed proposalId, uint256 indexed totalBoostReward);
    event BoostRewardTransferred(uint256 indexed proposalId,address indexed validator,uint256 rewardAmount);
    event ProposalCancelled(uint256 indexed proposalId);
    event BoostProposalCancelled(uint256 indexed proposalId);
    event RewardsClaimedAndLocked(address indexed sender, uint256 proposalId, uint256 rewardAmount);
    event RewardDistributionExecuted(uint256 indexed proposalId, uint256 totalReward, uint256 timestamp);
    event VotesReset(address indexed sender, uint256 currentCycle);

    /**
    * @dev Resets the votes for a given user. This function will clear all vote-related data for the specified user.
    * This could be used, for example, to allow users to re-cast their votes or to reset their voting status after a certain event.
    * @param _user The address of the user whose votes are to be reset.
    */
    function resetVotes(address _user) external;

    /**
    * @dev Checks if the given proposal ID corresponds to a "boost vote" proposal.
    * A boost vote might refer to a special type of vote, possibly with enhanced or different effects.
    * @param _proposalId The ID of the proposal to be checked.
    * @return bool True if the proposal ID is a boost vote, false otherwise.
    */
    function isBoostVote(uint256 _proposalId) external view returns (bool);

}