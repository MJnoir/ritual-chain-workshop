# Privacy-Preserving AI Bounty Judge — Commit-Reveal

> Ritual Academy Homework #1 — Modified by MJnoir

## Overview

This is an updated version of the AI Bounty Judge workshop contract. The original version had a critical flaw: **answers were public immediately after submission**, allowing later participants to read and copy earlier answers.

This version fixes that by implementing a **commit-reveal flow**: participants submit only a hash during the submission phase, and reveal their actual answer in a separate phase after the submission window closes.

---

## Bounty Lifecycle
[Create Bounty]
│
▼
[Commit Phase] (now → submitDeadline)
Participants submit: keccak256(answer + salt + sender + bountyId)
✗ Answers are NOT visible on-chain
│
▼ submitDeadline passes
│
[Reveal Phase] (submitDeadline → revealDeadline)
Participants submit: answer + salt
Contract verifies the hash matches
✓ Only valid reveals are eligible for judging
│
▼ revealDeadline passes
│
[Judge Phase]
Owner calls judgeAll() → Ritual AI scores all revealed answers in one batch
│
▼
[Finalize]
Owner calls finalizeWinner(index) → reward paid to winner
---

## Key Contract Functions

| Function | Who | When |
|---|---|---|
| `createBounty(title, rubric, submitDeadline, revealDeadline)` | Owner | Anytime |
| `submitCommitment(bountyId, commitment)` | Participant | Before submitDeadline |
| `revealAnswer(bountyId, answer, salt)` | Participant | Between deadlines |
| `judgeAll(bountyId, llmInput)` | Owner | After revealDeadline |
| `finalizeWinner(bountyId, winnerIndex)` | Owner | After judging |

---

## How to Compute Your Commitment (off-chain)

```js
const { ethers } = require("ethers");

const answer   = "My answer to the bounty question";
const salt     = ethers.randomBytes(32);
const sender   = "0xYourWalletAddress";
const bountyId = 1n;

const commitment = ethers.solidityPackedKeccak256(
  ["string", "bytes32", "address", "uint256"],
  [answer, salt, sender, bountyId]
);
```

---

## Contract Rules

- One commitment per address per bounty
- Commitments only accepted before submitDeadline
- Reveals only accepted between submitDeadline and revealDeadline
- Reveal must match the original commitment hash exactly
- Only revealed answers are passed to Ritual AI for judging
- judgeAll() is one batch call — not one LLM call per submission
- finalizeWinner() requires the winner index to point to a revealed submission
- Only one winner receives the full reward

---

## Architecture Note: Commit-Reveal vs Ritual-Native

### Commit-Reveal (This Implementation)

Works on any EVM chain. Participants hash their answer off-chain before submitting. The plaintext answer never hits the chain during the submission window.

**Limitation:** Answers become public during the reveal phase, before AI judging completes.

### Ritual-Native Encrypted Submissions (Advanced Track)

Participants encrypt their answer using the Ritual TEE public key. Ciphertext is stored on-chain or via IPFS reference. During judgeAll(), the TEE decrypts all answers privately and sends them to the LLM in one batch. Plaintext answers are never exposed on the public chain.

| Data | Location |
|---|---|
| Encrypted submission | On-chain or IPFS hash on-chain |
| Plaintext answer | Only inside Ritual TEE during judging |
| AI verdict + winner index | On-chain after judging |
| Revealed answer bundle | IPFS (hash committed on-chain) |

---

## Test Plan

### Valid Cases
| Test | Expected |
|---|---|
| Submit commitment before submitDeadline | Stored on-chain, hasCommitted = true |
| Reveal with correct answer + salt after submitDeadline | revealed = true, answer stored |
| judgeAll() after revealDeadline with 1+ revealed answer | Ritual AI called, judged = true |
| finalizeWinner() with valid revealed winner index | Reward transferred to winner |

### Invalid / Edge Cases
| Test | Expected |
|---|---|
| Submit commitment after submitDeadline | Revert: commit phase closed |
| Submit two commitments from same address | Revert: already committed |
| Reveal before submitDeadline | Revert: reveal phase not started |
| Reveal after revealDeadline | Revert: reveal phase closed |
| Reveal with wrong salt/answer | Revert: commitment mismatch |
| Reveal twice | Revert: already revealed |
| judgeAll() before revealDeadline | Revert: reveal phase not over |
| judgeAll() with zero revealed submissions | Revert: no revealed submissions |
| finalizeWinner() with unrevealed index | Revert: winner must have revealed |
| Non-owner calls judgeAll() | Revert: not bounty owner |

---

## Reflection

In a fair bounty system, submission content should stay hidden until judging is complete — making answers public during an active submission window lets late participants copy and improve on earlier work, undermining the integrity of the competition. The commitment hash and submitter address can be public, since they prove participation without revealing content. The judging rubric should also be public so participants know what criteria they are being evaluated against. AI should handle the objective scoring — comparing answers against the rubric at scale and producing a ranked output with reasons. This is where Ritual's batch judging shines: one LLM call sees all answers together and can compare them fairly rather than scoring in isolation. However, the final winner selection should remain a human decision: the bounty owner reviews the AI recommendation and calls finalizeWinner() manually. This preserves accountability and ensures the AI output is a recommendation rather than an automatic payout trigger. The payout itself — once the owner finalizes — should be automatic and trustless, executed by the contract with no further human intervention needed.
