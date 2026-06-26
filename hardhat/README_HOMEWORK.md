# Privacy-Preserving AI Bounty Judge

## What changed
This version replaces public answer submission with a commit-reveal flow.

## New bounty lifecycle
1. Owner creates a bounty with:
   - reward
   - submission deadline
   - reveal deadline
2. During the submission phase, each participant submits only a `bytes32 commitment`.
3. The commitment is computed as:
   `keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))`
4. During the reveal phase, the participant reveals `answer` and `salt`.
5. The contract recomputes the hash and accepts the reveal only if it matches the stored commitment.
6. Only valid revealed answers are added to the list that can be judged.
7. After the reveal deadline, the bounty owner calls `judgeAll()`.
8. On Ritual (`chainId == 1979`) `judgeAll()` can use the Ritual LLM precompile. On another EVM chain it stores the provided `llmInput` as a placeholder so the core commit-reveal flow still works.
9. The owner reviews the AI output and then calls `finalizeWinner()` to pay exactly one revealed winner.

## Required functions included
- `submitCommitment(uint256 bountyId, bytes32 commitment)`
- `revealAnswer(uint256 bountyId, string calldata answer, bytes32 salt)`
- `judgeAll(uint256 bountyId, bytes calldata llmInput)`
- `finalizeWinner(uint256 bountyId, uint256 winnerIndex)`

## Test plan
### Valid cases
- User can submit one commitment before the submission deadline.
- User can reveal only after the submission deadline.
- A correct `(answer, salt)` pair is accepted.
- Only revealed answers are counted for judging.
- Owner can judge only after the reveal deadline.
- Owner can finalize only after `judgeAll()`.

### Invalid cases
- A second commitment from the same address should revert.
- A reveal before the submission deadline should revert.
- A reveal after the reveal deadline should revert.
- A reveal with the wrong salt should revert.
- Judging before the reveal deadline should revert.
- Finalizing with an out-of-range `winnerIndex` should revert.

## Reflection answer
In a bounty system, the reward amount, rubric, deadlines, and final winner should be public because they affect trust and fairness. The submission contents should stay hidden during the competition period so later participants cannot copy earlier work. A commitment hash should be public because it proves a submission existed at a certain time without revealing the content. AI is useful for ranking answers against a rubric, summarizing strengths and weaknesses, and producing a consistent first-pass recommendation. A human should still make the final payout decision, especially when quality is subjective or the AI output may be ambiguous. If private data or proprietary work is involved, plaintext should exist only with the author and, at the correct phase, inside a trusted judging environment. The final system should reveal enough information for auditability without leaking answers too early.
