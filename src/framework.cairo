//! The confidential shard framework — a minimal, frozen, logic-agnostic verifier +
//! dispatcher.
//!
//! It NEVER chooses the logic: the virtual `transition` `library_call`s whatever
//! `logic_class_hash` is committed in the state, and relays whatever successor that
//! logic returns. The on-chain `apply_transition` is structurally identical to the
//! monolithic v1 (proof<->message binding + CAS); only the state schema and the
//! virtual dispatcher are new.
//!
//! DO NOT add `replace_class`, an owner/admin, or any `root` setter here. The
//! framework being frozen and address-pinned is precisely what makes a shard's
//! logic-immutability real: if the framework could be swapped or `root` re-anchored,
//! an immutable logic could be bypassed.

#[starknet::contract]
pub mod ConfidentialShard {
    use core::poseidon::poseidon_hash_span;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::syscalls::{get_execution_info_v3_syscall, send_message_to_l1_syscall};
    use starknet::{ContractAddress, SyscallResultTrait, get_contract_address};
    use crate::interfaces::{
        ILogicDispatcherTrait, ILogicLibraryDispatcher, IShard, PublicMessage, ShardState,
    };

    // SNIP-36 constants — VERIFIED end-to-end on Sepolia 2026-07-02. proof_facts[7]
    // = number of L2->L1 messages, [8] = Poseidon hash of the first message; the
    // on-chain compute_message_hash reproduced [8] exactly. to_address = 0.
    const PROOF_FACTS_N_MSG_INDEX: usize = 7;
    const PROOF_FACTS_MSG_HASH_INDEX: usize = 8;
    const MSG_TO_ADDRESS: felt252 = 0;

    #[storage]
    struct Storage {
        // The entire on-chain footprint: one commitment to the confidential state.
        root: felt252,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Transitioned: Transitioned,
    }

    #[derive(Drop, starknet::Event)]
    struct Transitioned {
        #[key]
        old_root: felt252,
        new_root: felt252,
    }

    /// Genesis. `genesis_root` = commit(logic_class_hash0, app_state0, salt), computed
    /// OFF-CHAIN by the deployer — the class hash and state are secret, so the chain
    /// never learns which logic bootstraps the shard.
    #[constructor]
    fn constructor(ref self: ContractState, genesis_root: felt252) {
        assert!(genesis_root != 0, "genesis_root_zero");
        self.root.write(genesis_root);
    }

    #[abi(embed_v0)]
    impl ConfidentialShardImpl of IShard<ContractState> {
        // VIRTUAL: runs only inside the prover. Access posture: intentionally public;
        // mutates no on-chain storage. `library_call` runs the committed logic in THIS
        // contract's context, so the emitted message's from_address is this contract.
        fn transition(
            ref self: ContractState,
            public_input: Array<felt252>,
            private_input: ShardState,
            new_salt: felt252,
        ) {
            let ShardState { logic_class_hash, app_state, salt } = private_input;

            // old_root binds the committed logic_class_hash to the live anchor via the CAS.
            let old_root = commit(logic_class_hash, @app_state, salt);

            // Run exactly the committed logic. The class hash comes from private_input
            // (the committed preimage), NEVER from public_input — that is the invariant
            // that makes the logic tamper-proof.
            let logic = ILogicLibraryDispatcher {
                class_hash: logic_class_hash.try_into().expect('bad logic class hash'),
            };
            let (next_logic_class_hash, new_app_state, outputs) = logic
                .step(logic_class_hash, app_state, public_input);

            // Cheap brick-guard. We cannot verify the successor is declared or
            // interface-compatible (that only fails at the next proof) — accepted risk.
            assert!(next_logic_class_hash != 0, "next_logic_zero");

            // Rotate the blinding factor: the successor state commits under a FRESH,
            // caller-supplied salt, so recovering one transition's salt cannot
            // deanonymize any other transition (fixes the constant-salt-reuse finding).
            // The caller must supply high-entropy randomness; the framework can only
            // cheaply reject the degenerate zero salt.
            assert!(new_salt != 0, "new_salt_zero");
            let new_root = commit(next_logic_class_hash, @new_app_state, new_salt);

            let msg = PublicMessage { old_root, new_root, outputs };
            let mut payload: Array<felt252> = array![];
            msg.serialize(ref payload);
            send_message_to_l1_syscall(MSG_TO_ADDRESS, payload.span()).unwrap_syscall();
        }

        // ON-CHAIN. Logic-agnostic: it never sees or checks logic_class_hash. Security
        // is the proof<->message binding plus the CAS on `root`, not caller identity.
        fn apply_transition(ref self: ContractState, msg: PublicMessage) {
            let exec = get_execution_info_v3_syscall().unwrap_syscall().unbox();
            let tx_info = exec.tx_info.unbox();
            let proof_facts = tx_info.proof_facts;

            assert(*proof_facts.at(PROOF_FACTS_N_MSG_INDEX) == 1, 'expected 1 message');

            let h = compute_message_hash(get_contract_address(), @msg);
            assert(*proof_facts.at(PROOF_FACTS_MSG_HASH_INDEX) == h, 'proof/msg mismatch');

            // CAS: both concurrency safety and replay protection in one line.
            assert(msg.old_root == self.root.read(), 'stale root');
            self.root.write(msg.new_root);

            self.emit(Transitioned { old_root: msg.old_root, new_root: msg.new_root });
        }

        fn get_root(self: @ContractState) -> felt252 {
            self.root.read()
        }
    }

    /// Commitment over the FULL confidential state, INCLUDING the logic class hash.
    /// Layout `[logic_class_hash, app_state.len, ...app_state, salt]` — the length
    /// prefix prevents ambiguity between different app_state splittings. MUST be
    /// byte-identical to any off-chain reconstruction.
    fn commit(logic_class_hash: felt252, app_state: @Array<felt252>, salt: felt252) -> felt252 {
        let mut data: Array<felt252> = array![logic_class_hash, app_state.len().into()];
        for x in app_state.span() {
            data.append(*x);
        }
        data.append(salt);
        poseidon_hash_span(data.span())
    }

    /// Recompute the Poseidon hash of the single L2->L1 message to compare against
    /// proof_facts[8]. Preimage `[from, to_address, payload_len, ...payload]` where
    /// payload = Serde(PublicMessage). VERIFIED on Sepolia 2026-07-02.
    fn compute_message_hash(from: ContractAddress, msg: @PublicMessage) -> felt252 {
        let mut payload: Array<felt252> = array![];
        msg.serialize(ref payload);
        let mut data: Array<felt252> = array![from.into(), MSG_TO_ADDRESS, payload.len().into()];
        for f in payload.span() {
            data.append(*f);
        }
        poseidon_hash_span(data.span())
    }
}
