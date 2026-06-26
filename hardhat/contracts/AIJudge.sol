// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

abstract contract PrecompileConsumer {
    address internal constant LLM_INFERENCE_PRECOMPILE = address(0x0802);

    function _executePrecompile(
        address precompile,
        bytes memory input
    ) internal returns (bytes memory) {
        (bool success, bytes memory rawOutput) = precompile.call(input);

        if (!success) {
            assembly {
                revert(add(rawOutput, 32), mload(rawOutput))
            }
        }

        (, bytes memory actualOutput) = abi.decode(rawOutput, (bytes, bytes));
        return actualOutput;
    }
}

contract AIJudge is PrecompileConsumer {
    uint256 public constant MAX_SUBMISSIONS = 10;
    uint256 public constant MAX_ANSWER_LENGTH = 2_000;

    uint256 public nextBountyId = 1;

    struct Submission {
        address submitter;
        string answer;
    }

    struct Bounty {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 submissionDeadline;
        uint256 revealDeadline;
        uint256 commitmentCount;
        bool judged;
        bool finalized;
        bytes aiReview;
        uint256 winnerIndex;
        Submission[] revealedSubmissions;
    }

    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    mapping(uint256 => Bounty) private bounties;
    mapping(uint256 => mapping(address => bytes32)) public commitments;
    mapping(uint256 => mapping(address => bool)) public revealed;

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed owner,
        string title,
        uint256 reward,
        uint256 submissionDeadline,
        uint256 revealDeadline
    );

    event CommitmentSubmitted(
        uint256 indexed bountyId,
        address indexed submitter,
        bytes32 commitment
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
        uint256 submissionDeadline,
        uint256 revealDeadline
    ) external payable returns (uint256 bountyId) {
        require(msg.value > 0, "reward required");
        require(submissionDeadline > block.timestamp, "submission too early");
        require(revealDeadline > submissionDeadline, "bad reveal deadline");

        bountyId = nextBountyId++;

        Bounty storage bounty = bounties[bountyId];
        bounty.owner = msg.sender;
        bounty.title = title;
        bounty.rubric = rubric;
        bounty.reward = msg.value;
        bounty.submissionDeadline = submissionDeadline;
        bounty.revealDeadline = revealDeadline;
        bounty.winnerIndex = type(uint256).max;

        emit BountyCreated(
            bountyId,
            msg.sender,
            title,
            msg.value,
            submissionDeadline,
            revealDeadline
        );
    }

    function submitCommitment(
        uint256 bountyId,
        bytes32 commitment
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp < bounty.submissionDeadline, "submissions closed");
        require(!bounty.judged, "already judged");
        require(!bounty.finalized, "already finalized");
        require(commitment != bytes32(0), "empty commitment");
        require(commitments[bountyId][msg.sender] == bytes32(0), "already committed");
        require(bounty.commitmentCount < MAX_SUBMISSIONS, "too many submissions");

        commitments[bountyId][msg.sender] = commitment;
        bounty.commitmentCount += 1;

        emit CommitmentSubmitted(bountyId, msg.sender, commitment);
    }

    function revealAnswer(
        uint256 bountyId,
        string calldata answer,
        bytes32 salt
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp >= bounty.submissionDeadline, "reveal not started");
        require(block.timestamp < bounty.revealDeadline, "reveal closed");
        require(!bounty.judged, "already judged");
        require(!bounty.finalized, "already finalized");
        require(bytes(answer).length <= MAX_ANSWER_LENGTH, "answer too long");
        require(commitments[bountyId][msg.sender] != bytes32(0), "no commitment");
        require(!revealed[bountyId][msg.sender], "already revealed");

        bytes32 computed = keccak256(
            abi.encodePacked(answer, salt, msg.sender, bountyId)
        );
        require(computed == commitments[bountyId][msg.sender], "bad reveal");

        revealed[bountyId][msg.sender] = true;
        bounty.revealedSubmissions.push(
            Submission({submitter: msg.sender, answer: answer})
        );

        emit AnswerRevealed(
            bountyId,
            bounty.revealedSubmissions.length - 1,
            msg.sender
        );
    }

    function judgeAll(
        uint256 bountyId,
        bytes calldata llmInput
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp >= bounty.revealDeadline, "reveal not over");
        require(!bounty.judged, "already judged");
        require(!bounty.finalized, "already finalized");
        require(bounty.revealedSubmissions.length > 0, "no revealed submissions");

        bytes memory completionData;

        // On Ritual testnet/mainnet, use the native LLM precompile.
        // On any other EVM chain, store the provided llmInput as a placeholder so
        // the required commit-reveal flow still works without Ritual-specific infra.
        if (block.chainid == 1979) {
            bytes memory output = _executePrecompile(
                LLM_INFERENCE_PRECOMPILE,
                llmInput
            );

            (
                bool hasError,
                bytes memory ritualCompletion,
                ,
                string memory errorMessage,

            ) = abi.decode(output, (bool, bytes, bytes, string, ConvoHistory));

            require(!hasError, errorMessage);
            completionData = ritualCompletion;
        } else {
            completionData = llmInput;
        }

        bounty.judged = true;
        bounty.aiReview = completionData;

        emit AllAnswersJudged(bountyId, completionData);
    }

    function finalizeWinner(
        uint256 bountyId,
        uint256 winnerIndex
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(bounty.judged, "not judged yet");
        require(!bounty.finalized, "already finalized");
        require(
            winnerIndex < bounty.revealedSubmissions.length,
            "invalid winner index"
        );

        bounty.finalized = true;
        bounty.winnerIndex = winnerIndex;

        address winner = bounty.revealedSubmissions[winnerIndex].submitter;
        uint256 reward = bounty.reward;
        bounty.reward = 0;

        (bool ok, ) = payable(winner).call{value: reward}("");
        require(ok, "payment failed");

        emit WinnerFinalized(bountyId, winnerIndex, winner, reward);
    }

    function getBountyMeta(
        uint256 bountyId
    )
        external
        view
        bountyExists(bountyId)
        returns (
            address owner,
            string memory title,
            string memory rubric,
            uint256 reward,
            uint256 submissionDeadline,
            uint256 revealDeadline
        )
    {
        Bounty storage bounty = bounties[bountyId];

        return (
            bounty.owner,
            bounty.title,
            bounty.rubric,
            bounty.reward,
            bounty.submissionDeadline,
            bounty.revealDeadline
        );
    }

    function getBountyStatus(
        uint256 bountyId
    )
        external
        view
        bountyExists(bountyId)
        returns (
            uint256 commitmentCount,
            uint256 revealedCount,
            bool judged,
            bool finalized,
            uint256 winnerIndex,
            bytes memory aiReview
        )
    {
        Bounty storage bounty = bounties[bountyId];

        return (
            bounty.commitmentCount,
            bounty.revealedSubmissions.length,
            bounty.judged,
            bounty.finalized,
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
        returns (address submitter, string memory answer)
    {
        Bounty storage bounty = bounties[bountyId];

        require(index < bounty.revealedSubmissions.length, "invalid index");

        Submission storage submission = bounty.revealedSubmissions[index];
        return (submission.submitter, submission.answer);
    }

    function computeCommitment(
        uint256 bountyId,
        address submitter,
        string calldata answer,
        bytes32 salt
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(answer, salt, submitter, bountyId));
    }
}
