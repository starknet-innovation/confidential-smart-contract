//! The confidential counter shard contract.
//!
//! ONE class exposes both sides of the SNIP-36 pair, deployed at ONE address so
//! `get_contract_address()` matches between the virtual emit and the on-chain
//! recompute:
//!   - `transition`       — VIRTUAL, proven off-chain (emits the L2->L1 message)
//!   - `apply_transition` — ON-CHAIN, verifies {proof, proofFacts} and CAS the root

#[starknet::contract]
pub mod ConfidentialCounter {
    use core::poseidon::poseidon_hash_span;
    use starknet::{ContractAddress, get_contract_address};
    use starknet::syscalls::{send_message_to_l1_syscall, get_execution_info_v3_syscall};
    use starknet::SyscallResultTrait;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use crate::interfaces::{ICounterShard, Action, PreState, PublicMessage};

    // ─── SNIP-36 constants — VERIFIED end-to-end on Sepolia 2026-07-02 ───────
    // Confirmed against a real strkd on-device proof (ref block ~11480759,
    // Starknet v0.14.3): proof_facts had 9 felts with [7]=n_messages=1 and
    // [8]=Poseidon hash of the first L2->L1 message. The on-chain
    // compute_message_hash below reproduced proof_facts[8] EXACTLY, and Tx B
    // (apply_transition) verified the binding and CAS-advanced the root.
    // to_address=0 matched. (Originally unconfirmed vs the reference impl, whose
    // Cairo examples recompute results on-chain instead of reading proof_facts.)
    //
    // proof_facts layout (verified):
    //   [7] = number of L2->L1 messages emitted
    //   [8] = Poseidon hash of the first L2->L1 message
    const PROOF_FACTS_N_MSG_INDEX: usize = 7;
    const PROOF_FACTS_MSG_HASH_INDEX: usize = 8;
    // L2->L1 `to_address`, used in BOTH the virtual emit and the on-chain hash
    // recompute — the two MUST match. Verified: 0 works under SNIP-36.
    const MSG_TO_ADDRESS: felt252 = 0;
    // ─────────────────────────────────────────────────────────────────────────

    #[storage]
    struct Storage {
        // The whole on-chain footprint: one commitment to the off-chain state.
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
        step: felt252,
    }

    /// Genesis. `root` MUST be `commit(initial_state)` computed OFF-CHAIN by the
    /// deployer — the state and its salt are secret, so the contract cannot
    /// compute the genesis commitment itself. See DESIGN.md sharp edge #7.
    #[constructor]
    fn constructor(ref self: ContractState, genesis_root: felt252) {
        // A real Poseidon commitment is never 0; reject the "forgot to set it" case.
        assert!(genesis_root != 0, "genesis_root_zero");
        self.root.write(genesis_root);
    }

    #[abi(embed_v0)]
    impl CounterShardImpl of ICounterShard<ContractState> {
        // VIRTUAL: runs only inside the prover. Reads nothing from chain storage;
        // it self-attests `old_root = commit(private_input)` and lets the chain
        // decide (via CAS) whether that claim is live.
        //
        // Access posture: intentionally PUBLIC. It mutates no storage; an on-chain
        // invocation would merely emit an L2->L1 message and change nothing.
        fn transition(ref self: ContractState, public_input: Action, private_input: PreState) {
            let old_root = commit(@private_input);

            // The counter transition itself: count += step, salt carried over.
            let new_state = PreState {
                count: private_input.count + public_input.step,
                salt: private_input.salt,
            };
            let new_root = commit(@new_state);

            // Publish ONLY the public claim as the proof's output.
            let msg = PublicMessage { old_root, new_root, step: public_input.step };
            let mut payload: Array<felt252> = array![];
            msg.serialize(ref payload);
            send_message_to_l1_syscall(MSG_TO_ADDRESS, payload.span()).unwrap_syscall();
        }

        // ON-CHAIN. Access posture: intentionally PUBLIC. Security comes from the
        // proof<->message binding plus the CAS on `root`, NOT from caller identity.
        // Only someone who knows the confidential pre-state can produce a proof
        // whose `old_root` matches the live anchor.
        fn apply_transition(ref self: ContractState, msg: PublicMessage) {
            // (0) Read the proof_facts the sequencer injected into this tx.
            // VERIFY: assumes get_execution_info_v3_syscall exists and TxInfo
            // exposes `proof_facts` (SNIP-36 corelib extension).
            let exec = get_execution_info_v3_syscall().unwrap_syscall().unbox();
            let tx_info = exec.tx_info.unbox();
            let proof_facts = tx_info.proof_facts;

            // Sanity: exactly one L2->L1 message was proven. VERIFY index.
            assert(*proof_facts.at(PROOF_FACTS_N_MSG_INDEX) == 1, 'expected 1 message');

            // (1) proof <-> message binding. VERIFY index + hash formula.
            let h = compute_message_hash(get_contract_address(), @msg);
            assert(*proof_facts.at(PROOF_FACTS_MSG_HASH_INDEX) == h, 'proof/msg mismatch');

            // (2) message <-> live anchor: compare-and-swap. This single check
            // gives BOTH concurrency safety and replay protection — once the root
            // advances, older proofs no longer match.
            assert(msg.old_root == self.root.read(), 'stale root');
            self.root.write(msg.new_root);

            // (3) Act on public outputs; the event doubles as an optional DA channel.
            self.emit(Transitioned {
                old_root: msg.old_root, new_root: msg.new_root, step: msg.step,
            });
        }

        fn get_root(self: @ContractState) -> felt252 {
            self.root.read()
        }
    }

    /// Full-state commitment. MUST be byte-identical to any off-chain
    /// reconstruction — same field order, same Poseidon domain. A single
    /// mismatch silently breaks every proof (DESIGN.md sharp edge #6).
    fn commit(state: @PreState) -> felt252 {
        poseidon_hash_span(array![*state.count, *state.salt].span())
    }

    /// Recompute the Poseidon hash of the (single) L2->L1 message, to compare
    /// against proof_facts[8]. VERIFIED on Sepolia 2026-07-02: this preimage
    /// ordering `[from_address, to_address, payload_len, ...payload]` with
    /// Poseidon reproduced the prover's proof_facts[8] exactly.
    fn compute_message_hash(from: ContractAddress, msg: @PublicMessage) -> felt252 {
        let mut payload: Array<felt252> = array![];
        (*msg).serialize(ref payload);

        let mut data: Array<felt252> = array![from.into(), MSG_TO_ADDRESS, payload.len().into()];
        for f in payload.span() {
            data.append(*f);
        };
        poseidon_hash_span(data.span())
    }
}
