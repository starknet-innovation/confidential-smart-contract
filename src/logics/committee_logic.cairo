//! Committee treasury logic — THE reference outbox example: a confidential M-of-N
//! committee whose threshold-approved decisions emit arbitrary public calls through the
//! framework outbox. "A private smart contract that emits commands which trigger other
//! public contracts."
//!
//! Authentication is **account-abstraction native**: members are Starknet ACCOUNTS
//! (addresses in app_state), and each approval is verified with SNIP-6
//! `is_valid_signature` — so a member may authenticate however its account does
//! (stark key, multisig, passkey, session key). The approval is a **SNIP-12 typed
//! message**, so members sign it with the standard wallet flow (`wallet_signTypedData`)
//! and the agent/orchestrator never touches key material.
//!
//! What stays confidential: the member set, the threshold, WHO approved, the nonce —
//! all live only in the commitment. The `is_valid_signature` checks run INSIDE the proof
//! (proven reads against the SNIP-36 reference block), so member addresses never touch
//! the chain. What is public: the resulting `actions` once recorded/consumed.
//!
//! app_state    = [nonce, threshold, n_members, member_addr_1 .. member_addr_n]
//! public_input = Serde(Array<PublicCall>) ++ Serde(Array<MemberSig>)
//!                MemberSig = { signer: ContractAddress, signature: Array<felt252> }
//!
//! Replay safety (SNIP-12 domain + message): the domain binds name/version + `chainId`
//! (no cross-chain replay); the message binds `shard` (no cross-shard replay) and
//! `nonce` (no within-shard replay — the nonce advances every step, and the CAS makes
//! each transition single-use anyway). SNIP-12 also folds the signer's address into the
//! hash, so a member's approval is bound to that member.
//!
//! IMMUTABLE (self-perpetuating): ships no upgrade or member-rotation path. A production
//! variant would accept a threshold-signed directive to rotate members / threshold /
//! logic — the same verification machinery applied to a different typed message.
//!
//! CAVEAT (audit, blind-signing): the SNIP-12 message carries only the opaque
//! `calls_hash`, not the decoded calls, so a signer's wallet cannot display what the
//! treasury will actually do — whatever bundle matches the signed hash executes. The
//! signing SDK MUST derive `calls_hash` from the human-readable calls the member
//! reviewed (the shipped `approvalTypedData` does). A production committee that wants
//! wallet-decodable approvals should enumerate the calls in the typed message instead.

use starknet::ContractAddress;

/// SNIP-6 account signature-validation surface — the AA-native auth primitive.
#[starknet::interface]
pub trait ISRC6<TState> {
    fn is_valid_signature(self: @TState, hash: felt252, signature: Array<felt252>) -> felt252;
}

/// One member's approval: the member's account + the signature its account accepts.
#[derive(Drop, Serde)]
pub struct MemberSig {
    pub signer: ContractAddress,
    pub signature: Array<felt252>,
}

#[starknet::contract]
pub mod CommitteeLogic {
    use core::hash::{HashStateTrait, HashStateExTrait};
    use core::poseidon::PoseidonTrait;
    use core::poseidon::poseidon_hash_span;
    use starknet::{ContractAddress, get_contract_address, get_tx_info};
    use openzeppelin_utils::cryptography::snip12::{StarknetDomain, StructHash};
    use crate::interfaces::{ILogic, PublicCall};
    use super::{ISRC6DispatcherTrait, ISRC6Dispatcher, MemberSig};

    /// SNIP-12 type hash of the approval message. Pinned from starknet.js
    /// (`typedData.getTypeHash`) for the type
    /// `"Approval"("shard":"ContractAddress","nonce":"felt","calls_hash":"felt")`.
    /// A cross-check test asserts this matches the off-chain SDK.
    pub const APPROVAL_TYPE_HASH: felt252 =
        0x250b8c480bdb8e8b17c9ed787dbc94629a557074c1d66a1a42547ad2d6248b7;
    /// SNIP-12 domain metadata (matches the off-chain SDK's TypedData domain). NOTE:
    /// `version` is the felt `1`, NOT the shortstring `'1'` (0x31) — starknet.js encodes
    /// a numeric-looking shortstring like "1" as the felt 0x1, and the cross-check test
    /// pins this.
    pub const DOMAIN_NAME: felt252 = 'ConfShardCommittee';
    pub const DOMAIN_VERSION: felt252 = 1;
    /// SRC-6 success sentinel.
    const VALID: felt252 = 'VALID';

    #[storage]
    struct Storage {}

    /// The SNIP-12 approval message: bind the shard, the committee nonce, and the exact
    /// call bundle (by hash). The signer address is folded in by SNIP-12 itself.
    #[derive(Drop, Copy)]
    pub struct CommitteeApproval {
        pub shard: felt252,
        pub nonce: felt252,
        pub calls_hash: felt252,
    }

    impl CommitteeApprovalStructHash of StructHash<CommitteeApproval> {
        fn hash_struct(self: @CommitteeApproval) -> felt252 {
            PoseidonTrait::new()
                .update_with(APPROVAL_TYPE_HASH)
                .update_with(*self.shard)
                .update_with(*self.nonce)
                .update_with(*self.calls_hash)
                .finalize()
        }
    }

    #[abi(embed_v0)]
    impl CommitteeLogicImpl of ILogic<ContractState> {
        fn step(
            self: @ContractState,
            logic_class_hash: felt252,
            app_state: Array<felt252>,
            public_input: Array<felt252>,
        ) -> (felt252, Array<felt252>, Array<felt252>, Array<PublicCall>) {
            // --- committee state ---
            let nonce = *app_state.at(0);
            let threshold: u32 = (*app_state.at(1)).try_into().expect('bad threshold');
            let n_members: u32 = (*app_state.at(2)).try_into().expect('bad n_members');
            assert(threshold >= 1, 'zero threshold');
            assert(threshold <= n_members, 'threshold > members');
            // v5: app_state = [nonce, threshold, n, member_1..n, seed] — a trailing salt_kit
            // blinding `seed` keeps the member set hidden now the framework has no salt. The
            // successor copy loop below carries it forward automatically.
            assert(app_state.len() == 4 + n_members, 'bad app_state len');

            // --- proposal: the calls to execute + the member approvals ---
            let mut span = public_input.span();
            let calls: Array<PublicCall> = Serde::deserialize(ref span).expect('bad calls');
            let approvals: Array<MemberSig> = Serde::deserialize(ref span).expect('bad sigs');
            assert(span.len() == 0, 'trailing public_input');
            assert(calls.len() != 0, 'empty proposal');

            // Bind the approval to this shard, this nonce, and exactly these calls.
            let calls_hash = hash_calls(@calls);
            let shard = get_contract_address();

            // --- count distinct, valid member approvals (verified IN-PROOF via SNIP-6) ---
            let mut valid: u32 = 0;
            let mut seen: Array<felt252> = array![];
            for approval in approvals {
                let MemberSig { signer, signature } = approval;
                let signer_felt: felt252 = signer.into();
                assert(is_member(@app_state, n_members, signer_felt), 'not a member');
                for prev in seen.span() {
                    assert(*prev != signer_felt, 'duplicate signer');
                };
                // Per-member SNIP-12 hash (folds in the signer), verified by the member's
                // own account — AA-native: any signature scheme the account supports.
                let hash = approval_message_hash(shard.into(), nonce, calls_hash, signer);
                let ok = ISRC6Dispatcher { contract_address: signer }
                    .is_valid_signature(hash, signature);
                assert(ok == VALID, 'bad signature');
                seen.append(signer_felt);
                valid += 1;
            };
            assert(valid >= threshold, 'threshold not met');

            // --- successor: nonce advances, committee unchanged, logic immutable ---
            let mut new_app_state: Array<felt252> = array![nonce + 1];
            let mut i: u32 = 1;
            while i != app_state.len() {
                new_app_state.append(*app_state.at(i));
                i += 1;
            };

            // No outputs: the actions are the (eventual) public effect; the decision
            // stays in the commitment.
            (logic_class_hash, new_app_state, array![], calls)
        }
    }

    /// SNIP-12 message hash for `signer`, mirroring OZ's `OffchainMessageHash` (whose
    /// blanket impl is crate-private): 'StarkNet Message' ‖ domain ‖ signer ‖ struct.
    /// Uses OZ's audited `StarknetDomain` for the domain half.
    pub fn approval_message_hash(
        shard: felt252, nonce: felt252, calls_hash: felt252, signer: ContractAddress,
    ) -> felt252 {
        let domain = StarknetDomain {
            name: DOMAIN_NAME,
            version: DOMAIN_VERSION,
            chain_id: get_tx_info().unbox().chain_id,
            revision: 1,
        };
        let message = CommitteeApproval { shard, nonce, calls_hash };
        PoseidonTrait::new()
            .update_with('StarkNet Message')
            .update_with(domain.hash_struct())
            .update_with(signer)
            .update_with(message.hash_struct())
            .finalize()
    }

    /// poseidon(Serde(Array<PublicCall>)) — the same encoding the framework outbox uses,
    /// so the approved bundle and the recorded bundle are one and the same.
    fn hash_calls(calls: @Array<PublicCall>) -> felt252 {
        let mut data: Array<felt252> = array![];
        calls.serialize(ref data);
        poseidon_hash_span(data.span())
    }

    fn is_member(app_state: @Array<felt252>, n_members: u32, addr: felt252) -> bool {
        let mut i: u32 = 0;
        let mut found = false;
        while i != n_members {
            if *app_state.at(3 + i) == addr {
                found = true;
                break;
            }
            i += 1;
        };
        found
    }
}
