// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrecompileConsumer} from "./utils/PrecompileConsumer.sol";

interface IRitualWallet {
    function deposit(uint256 lockDuration) external payable;
    function depositFor(address user, uint256 lockDuration) external payable;
    function withdraw(uint256 amount) external;
    function balanceOf(address) external view returns (uint256);
    function lockUntil(address) external view returns (uint256);
}

/**
 * @title AIJudge — Privacy-Preserving Bounty Judge (Commit-Reveal)
 * @notice Submissions are hidden during the submission phase via commit-reveal.
 *         Only revealed answers are eligible for AI judging by Ritual.
 *
 * Lifecycle:
 *   1. Owner creates bounty with submitDeadline and revealDeadline.
 *   2. Participants submit keccak256(answer, salt, sender, bountyId) commitment hashes.
 *   3. After submitDeadline → reveal phase: participants reveal answer + salt.
 *   4. After revealDeadline → owner calls judgeAll() → Ritual AI judges all revealed answers.
 *   5. Owner calls finalizeWinner() → reward paid out.
 */
contract AIJudge is PrecompileConsumer {
    uint256 public constant MAX_SUBMISSIONS = 10;
    uint256 public constant MAX_ANSWER_LENGTH = 2_000;

    uint256 public nextBountyId = 1;

    IRitualWallet wallet =
        IRitualWallet(0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948);

    struct Submission {
        address submitter;
        bytes32 commitment;
        string  answer;
        bool    revealed;
    }

    struct Bounty {
        address owner;
        string  title;
        string  rubric;
        uint256 reward;
        uint256 submitDeadline;
        uint256 revealDeadline;
        bool    judged;
        bool    finalized;
        bytes   aiReview;
        uint256 winnerIndex;
        Submission[] submissions;
    }

    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    mapping(uint256 => Bounty) public bounties;
    mapping(uint256 => mapping(address => bool)) public hasCommitted;

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed owner,
        string  title,
        uint256 reward,
        uint256 submitDeadline,
        uint256 revealDeadline
    );

    event CommitmentSubmitted(
        uint256 indexed bountyId,
        uint256 indexed submissionIndex,
        address indexed submitter
    );

    event AnswerRevealed(
        uint256 indexed bountyId,
        uint256 indexed submissionIndex,
        address indexed submitter
    );

    event AllAnswersJudged(uint256 indexed bountyId, bytes aiReview);

    event WinnerFinalized(
        uint256 indexed bountyId,
        uint256 indexed winnerIndex,
        address indexed winner,
        uint256 reward
    );

    modifier onlyOwner(uint256 bountyId) {
        require(msg.sender == bounties[bountyId].owner, "not bounty owner");
        _;
    }

    modifier bountyExists(uint256 bountyId) {
        require(bounties[bountyId].owner != address(0), "bounty not found");
        _;
    }

    function createBounty(
        string calldata title,
        string calldata rubric,
        uint256 submitDeadline,
        uint256 revealDeadline
    ) external payable returns (uint256 bountyId) {
        require(msg.value > 0, "reward required");
        require(submitDeadline > block.timestamp, "submitDeadline in past");
        require(revealDeadline > submitDeadline, "revealDeadline must be after submitDeadline");

        bountyId = nextBountyId++;

        Bounty storage bounty = bounties[bountyId];
        bounty.owner          = msg.sender;
        bounty.title          = title;
        bounty.rubric         = rubric;
        bounty.reward         = msg.value;
        bounty.submitDeadline = submitDeadline;
        bounty.revealDeadline = revealDeadline;
        bounty.winnerIndex    = type(uint256).max;

        emit BountyCreated(bountyId, msg.sender, title, msg.value, submitDeadline, revealDeadline);
    }

    function submitCommitment(
        uint256 bountyId,
        bytes32 commitment
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp < bounty.submitDeadline, "commit phase closed");
        require(!bounty.judged,    "already judged");
        require(!bounty.finalized, "already finalized");
        require(!hasCommitted[bountyId][msg.sender], "already committed");
        require(bounty.submissions.length < MAX_SUBMISSIONS, "too many submissions");
        require(commitment != bytes32(0), "empty commitment");

        hasCommitted[bountyId][msg.sender] = true;

        bounty.submissions.push(Submission({
            submitter:  msg.sender,
            commitment: commitment,
            answer:     "",
            revealed:   false
        }));

        emit CommitmentSubmitted(bountyId, bounty.submissions.length - 1, msg.sender);
    }

    function revealAnswer(
        uint256 bountyId,
        string calldata answer,
        bytes32 salt
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp >= bounty.submitDeadline, "reveal phase not started");
        require(block.timestamp <  bounty.revealDeadline, "reveal phase closed");
        require(!bounty.judged,    "already judged");
        require(!bounty.finalized, "already finalized");
        require(bytes(answer).length > 0, "empty answer");
        require(bytes(answer).length <= MAX_ANSWER_LENGTH, "answer too long");

        uint256 idx = _findSubmission(bountyId, msg.sender);
        Submission storage sub = bounty.submissions[idx];
        require(!sub.revealed, "already revealed");

        bytes32 expected = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId));
        require(expected == sub.commitment, "commitment mismatch");

        sub.answer   = answer;
        sub.revealed = true;

        emit AnswerRevealed(bountyId, idx, msg.sender);
    }

    function judgeAll(
        uint256 bountyId,
        bytes calldata llmInput
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp >= bounty.revealDeadline, "reveal phase not over");
        require(!bounty.judged,    "already judged");
        require(!bounty.finalized, "already finalized");
        require(_countRevealed(bountyId) > 0, "no revealed submissions");

        bytes memory output = _executePrecompile(
            LLM_INFERENCE_PRECOMPILE,
            llmInput
        );

        (
            bool   hasError,
            bytes  memory completionData,
            ,
            string memory errorMessage,
        ) = abi.decode(output, (bool, bytes, bytes, string, ConvoHistory));

        require(!hasError, errorMessage);

        bounty.judged   = true;
        bounty.aiReview = completionData;

        emit AllAnswersJudged(bountyId, completionData);
    }

    function finalizeWinner(
        uint256 bountyId,
        uint256 winnerIndex
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(bounty.judged,     "not judged yet");
        require(!bounty.finalized, "already finalized");
        require(winnerIndex < bounty.submissions.length, "invalid winner index");
        require(bounty.submissions[winnerIndex].revealed, "winner must have revealed");

        bounty.finalized   = true;
        bounty.winnerIndex = winnerIndex;

        address winner = bounty.submissions[winnerIndex].submitter;
        uint256 reward = bounty.reward;
        bounty.reward  = 0;

        (bool ok, ) = payable(winner).call{value: reward}("");
        require(ok, "payment failed");

        emit WinnerFinalized(bountyId, winnerIndex, winner, reward);
    }

    function getBounty(
        uint256 bountyId
    )
        external
        view
        bountyExists(bountyId)
        returns (
            address owner,
            string  memory title,
            string  memory rubric,
            uint256 reward,
            uint256 submitDeadline,
            uint256 revealDeadline,
            bool    judged,
            bool    finalized,
            uint256 submissionCount,
            uint256 revealedCount,
            uint256 winnerIndex,
            bytes   memory aiReview
        )
    {
        Bounty storage bounty = bounties[bountyId];
        return (
            bounty.owner,
            bounty.title,
            bounty.rubric,
            bounty.reward,
            bounty.submitDeadline,
            bounty.revealDeadline,
            bounty.judged,
            bounty.finalized,
            bounty.submissions.length,
            _countRevealed(bountyId),
            bounty.winnerIndex,
            bounty.aiReview
        );
    }

    function getSubmission(
        uint256 bountyId,
        uint256 index
    )
        external
        view
        bountyExists(bountyId)
        returns (
            address submitter,
            bool    revealed,
            string  memory answer
        )
    {
        Bounty storage bounty = bounties[bountyId];
        require(index < bounty.submissions.length, "invalid index");
        Submission storage sub = bounty.submissions[index];
        return (
            sub.submitter,
            sub.revealed,
            sub.revealed ? sub.answer : ""
        );
    }

    function _findSubmission(
        uint256 bountyId,
        address submitter
    ) internal view returns (uint256) {
        Submission[] storage subs = bounties[bountyId].submissions;
        for (uint256 i = 0; i < subs.length; i++) {
            if (subs[i].submitter == submitter) return i;
        }
        revert("no commitment found for sender");
    }

    function _countRevealed(uint256 bountyId) internal view returns (uint256 count) {
        Submission[] storage subs = bounties[bountyId].submissions;
        for (uint256 i = 0; i < subs.length; i++) {
            if (subs[i].revealed) count++;
        }
    }
}
