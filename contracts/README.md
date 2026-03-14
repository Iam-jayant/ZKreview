# zkReview Cairo Contracts

Starknet contracts for bounty campaigns and review payouts.

## Build

Requires [Scarb](https://docs.swmansion.com/scarb/) (Cairo/Starknet toolchain):

```bash
cd contracts
scarb build
```

Artifacts: `target/dev/zkreview_BountyContract.contract_class.json`

## Contract: BountyContract

- **create_bounty(token, total_amount, reward_per_review, max_reviews, metadata_cid)**  
  Brand approves token and calls this; contract pulls `total_amount` and creates a bounty. Returns `bounty_id`.

- **submit_proof(bounty_id, proof_commitment)**  
  Reviewer registers a proof commitment (hash of zkTLS attestation). Must be called before `submit_review`.

- **submit_review(bounty_id, proof_commitment, review_cid)**  
  Reviewer submits IPFS CID of review; contract verifies proof was submitted by caller, then transfers `reward_per_review` to caller and emits events.

Events: `BountyCreated`, `ProofSubmitted`, `ReviewSubmitted`, `PayoutSent`.
