# Architecture Note: Commit-Reveal vs Ritual-Native Hidden Submissions

## 1) Required track: Commit-reveal
The generic EVM-safe solution is commit-reveal.

### Public on-chain
- bounty metadata
- reward
- submission deadline
- reveal deadline
- commitment hashes
- revealed answers after reveal phase
- AI review result / summary
- final winner

### Hidden during submission phase
- plaintext answer
- salt

### Fairness property
A participant cannot read another participant's answer before the reveal phase, so they cannot copy and improve it during the submission window.

### Limitation
Answers become public during the reveal phase, before or around the judging step. This is good enough for generic EVM fairness, but it does not keep answers private all the way through AI judging.

## 2) Advanced track: Ritual-native encrypted submissions
A stronger design uses Ritual TEE-backed execution.

### Suggested flow
1. Participant encrypts the answer for a Ritual TEE executor.
2. The contract stores only ciphertext or a reference to encrypted storage.
3. Other users cannot read the plaintext from chain state.
4. During `judgeAll()`, the TEE privately decrypts all submissions together.
5. The LLM receives the full batch inside the TEE and returns a ranking/review.
6. After judging, the system publishes a revealed bundle reference plus a bundle hash.
7. The owner finalizes the winner using the AI recommendation.

### Where plaintext exists
- with the participant before encryption
- inside the Ritual TEE during decryption and judging
- optionally inside a final revealed bundle after judging completes

### What is on-chain vs off-chain
On-chain:
- ciphertext or storage references
- hashes/commitments
- final AI result summary
- revealed bundle hash
- winner selection

Off-chain:
- encrypted answer blobs
- optional final answer bundle

### Why Ritual helps
Ritual provides TEE-backed execution, encrypted inputs/secrets, and batch LLM judging. That means the LLM can compare all answers together without exposing plaintext answers to other participants before the judging phase ends.
