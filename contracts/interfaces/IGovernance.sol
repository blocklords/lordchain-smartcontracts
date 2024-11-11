// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IGovernance {

    error InvalidWeight();
    error VotingNotOpen();
    error WrongTime();
    error WrongValue();
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
    
    event ProposalCreated(uint256 indexed proposalId, uint256 startTime, uint256 endTime, string metadataURI, uint256 totalChoices);
    event Voted(address indexed sender, uint256 proposalId, uint256 choiceIds, uint256 weights);
    event BoostProposalCreated(uint256 indexed proposalId, uint256 startTime, uint256 endTime, uint256 _boostReward, uint256 _boostStartTime, uint256 _boostEndTime, uint256 validatorsNum, address[] indexed validators);
    event BoostRewardDistributed(uint256 indexed proposalId, uint256 indexed totalBoostReward);
    event BoostRewardTransferred(uint256 indexed proposalId,address indexed validator,uint256 rewardAmount);
    event ProposalCancelled(uint256 indexed proposalId);
    event BoostProposalCancelled(uint256 indexed proposalId);
    event RewardsClaimedAndLocked(address indexed sender, uint256 proposalId, uint256 rewardAmount);
    event RewardDistributionExecuted(uint256 indexed proposalId, uint256 totalReward, uint256 timestamp);


    function resetVotes(address _user) external;

}