// zkReview: Bounty campaign and review registry.
// Brands create bounties, fund with ERC20; reviewers submit proof commitment then review CID and receive payout.
use starknet::ContractAddress;

#[starknet::interface]
pub trait IBountyContract<TContractState> {
    /// Create and fund a bounty. Caller must have approved this contract to spend `total_amount` of `token`.
    fn create_bounty(
        ref self: TContractState,
        token: ContractAddress,
        total_amount: u256,
        reward_per_review: u256,
        max_reviews: u64,
        metadata_cid: felt252,
    ) -> u64;
    /// Submit proof commitment (hash of zkTLS attestation). Caller must later submit_review for same bounty_id and commitment.
    fn submit_proof(ref self: TContractState, bounty_id: u64, proof_commitment: felt252);
    /// Submit review CID and receive payout. Requires prior submit_proof by caller for this bounty_id and proof_commitment.
    fn submit_review(
        ref self: TContractState,
        bounty_id: u64,
        proof_commitment: felt252,
        review_cid: felt252,
    );
    /// View: get bounty info.
    fn get_bounty(
        self: @TContractState,
        bounty_id: u64,
    ) -> (ContractAddress, ContractAddress, u256, u64, u64, u256, felt252, u8);
    /// View: get review CID for a reviewer on a bounty (0 if not submitted).
    fn get_review_cid(self: @TContractState, bounty_id: u64, reviewer: ContractAddress) -> felt252;
}

#[starknet::contract]
pub mod BountyContract {
    use super::ContractAddress;
    use crate::ierc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::{get_caller_address, get_contract_address};
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess, StoragePointerWriteAccess};

    #[storage]
    struct Storage {
        next_bounty_id: u64,
        bounty_funder: Map<u64, ContractAddress>,
        bounty_token: Map<u64, ContractAddress>,
        bounty_reward: Map<u64, u256>,
        bounty_max_reviews: Map<u64, u64>,
        bounty_filled: Map<u64, u64>,
        bounty_total_funded: Map<u64, u256>,
        bounty_metadata_cid: Map<u64, felt252>,
        bounty_status: Map<u64, u8>,
        proof_submitter: Map<(u64, felt252), ContractAddress>,
        review_cid: Map<(u64, ContractAddress), felt252>,
    }

    #[event]
    #[derive(Copy, Drop, Debug, PartialEq, starknet::Event)]
    pub enum Event {
        BountyCreated: BountyCreated,
        ProofSubmitted: ProofSubmitted,
        ReviewSubmitted: ReviewSubmitted,
        PayoutSent: PayoutSent,
    }

    #[derive(Copy, Drop, Debug, PartialEq, starknet::Event)]
    pub struct BountyCreated {
        pub bounty_id: u64,
        pub funder: ContractAddress,
        pub token: ContractAddress,
        pub reward_per_review: u256,
        pub max_reviews: u64,
        pub metadata_cid: felt252,
    }

    #[derive(Copy, Drop, Debug, PartialEq, starknet::Event)]
    pub struct ProofSubmitted {
        pub bounty_id: u64,
        pub reviewer: ContractAddress,
        pub proof_commitment: felt252,
    }

    #[derive(Copy, Drop, Debug, PartialEq, starknet::Event)]
    pub struct ReviewSubmitted {
        pub bounty_id: u64,
        pub reviewer: ContractAddress,
        pub review_cid: felt252,
    }

    #[derive(Copy, Drop, Debug, PartialEq, starknet::Event)]
    pub struct PayoutSent {
        pub bounty_id: u64,
        pub reviewer: ContractAddress,
        pub amount: u256,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        self.next_bounty_id.write(1);
    }

    #[abi(embed_v0)]
    impl BountyContractImpl of super::IBountyContract<ContractState> {
        fn create_bounty(
            ref self: ContractState,
            token: ContractAddress,
            total_amount: u256,
            reward_per_review: u256,
            max_reviews: u64,
            metadata_cid: felt252,
        ) -> u64 {
            let caller = get_caller_address();
            let bounty_id = self.next_bounty_id.read();
            self.next_bounty_id.write(bounty_id + 1);

            let this = get_contract_address();
            let mut token_dispatcher = IERC20Dispatcher { contract_address: token };
            token_dispatcher.transfer_from(caller, this, total_amount);

            self.bounty_funder.write(bounty_id, caller);
            self.bounty_token.write(bounty_id, token);
            self.bounty_reward.write(bounty_id, reward_per_review);
            self.bounty_max_reviews.write(bounty_id, max_reviews);
            self.bounty_filled.write(bounty_id, 0);
            self.bounty_total_funded.write(bounty_id, total_amount);
            self.bounty_metadata_cid.write(bounty_id, metadata_cid);
            self.bounty_status.write(bounty_id, 1);

            self.emit(Event::BountyCreated(BountyCreated {
                bounty_id,
                funder: caller,
                token,
                reward_per_review,
                max_reviews,
                metadata_cid,
            }));
            bounty_id
        }

        fn submit_proof(ref self: ContractState, bounty_id: u64, proof_commitment: felt252) {
            let caller = get_caller_address();
            assert(self.bounty_status.read(bounty_id) == 1, 'Bounty not open');
            assert(
                self.proof_submitter.read((bounty_id, proof_commitment))
                    == starknet::contract_address_const::<0>(),
                'Proof already used',
            );
            self.proof_submitter.write((bounty_id, proof_commitment), caller);
            self.emit(Event::ProofSubmitted(ProofSubmitted {
                bounty_id,
                reviewer: caller,
                proof_commitment,
            }));
        }

        fn submit_review(
            ref self: ContractState,
            bounty_id: u64,
            proof_commitment: felt252,
            review_cid: felt252,
        ) {
            let caller = get_caller_address();
            assert(self.bounty_status.read(bounty_id) == 1, 'Bounty not open');
            assert(self.proof_submitter.read((bounty_id, proof_commitment)) == caller, 'Proof not by caller');
            assert(self.review_cid.read((bounty_id, caller)) == 0, 'Already submitted');
            assert(review_cid != 0, 'Invalid review_cid');

            let filled = self.bounty_filled.read(bounty_id);
            let max_reviews = self.bounty_max_reviews.read(bounty_id);
            assert(filled < max_reviews, 'Bounty full');

            let reward = self.bounty_reward.read(bounty_id);
            let token = self.bounty_token.read(bounty_id);

            let mut token_dispatcher = IERC20Dispatcher { contract_address: token };
            token_dispatcher.transfer(caller, reward);

            self.bounty_filled.write(bounty_id, filled + 1);
            self.review_cid.write((bounty_id, caller), review_cid);

            if filled + 1 == max_reviews {
                self.bounty_status.write(bounty_id, 0);
            }

            self.emit(Event::ReviewSubmitted(ReviewSubmitted {
                bounty_id,
                reviewer: caller,
                review_cid,
            }));
            self.emit(Event::PayoutSent(PayoutSent {
                bounty_id,
                reviewer: caller,
                amount: reward,
            }));
        }

        fn get_bounty(
            self: @ContractState,
            bounty_id: u64,
        ) -> (ContractAddress, ContractAddress, u256, u64, u64, u256, felt252, u8) {
            (
                self.bounty_funder.read(bounty_id),
                self.bounty_token.read(bounty_id),
                self.bounty_reward.read(bounty_id),
                self.bounty_max_reviews.read(bounty_id),
                self.bounty_filled.read(bounty_id),
                self.bounty_total_funded.read(bounty_id),
                self.bounty_metadata_cid.read(bounty_id),
                self.bounty_status.read(bounty_id),
            )
        }

        fn get_review_cid(self: @ContractState, bounty_id: u64, reviewer: ContractAddress) -> felt252 {
            self.review_cid.read((bounty_id, reviewer))
        }
    }
}
