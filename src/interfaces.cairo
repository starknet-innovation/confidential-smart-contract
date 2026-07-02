//! Shared types + interfaces for the confidential shard framework.
//!
//! The framework is generic: it commits to an opaque `app_state` and delegates the
//! actual state transition to a pluggable logic class named by `logic_class_hash`.
//! Critically, `logic_class_hash` lives INSIDE the committed state, so which logic
//! governs a shard is itself confidential and enforced by the commitment.

/// The full confidential off-chain state. Committed to `root`; published nowhere.
///
/// `logic_class_hash` names the pluggable logic that governs this shard. It lives
/// inside the commitment, so it is enforced cryptographically: the on-chain CAS
/// pins `old_root` to the live anchor, and `old_root` pins `logic_class_hash` (a
/// prover cannot substitute a different logic without breaking Poseidon preimage
/// resistance). `salt` is the blinding factor that makes the commitment hiding — it
/// MUST be fresh, high-entropy, and is ROTATED every transition (each `transition`
/// supplies a new `new_salt` for the successor state), so recovering one transition's
/// salt cannot deanonymize any other. Reusing a low-entropy salt breaks hiding.
#[derive(Drop, Serde)]
pub struct ShardState {
    pub logic_class_hash: felt252,
    pub app_state: Array<felt252>,
    pub salt: felt252,
}

/// The public claim carried in the virtual function's L2->L1 message and
/// re-supplied verbatim as `apply_transition` calldata. `outputs` is whatever the
/// logic chose to make public this transition.
#[derive(Drop, Serde)]
pub struct PublicMessage {
    pub old_root: felt252,
    pub new_root: felt252,
    pub outputs: Array<felt252>,
}

/// The generic, frozen framework interface. This contract is the trust root: it is
/// address-pinned and must never gain an upgrade / admin / root-setter path.
#[starknet::interface]
pub trait IShard<TContractState> {
    /// VIRTUAL — proven off-chain. Commits `old_root` (current state), `library_call`s
    /// the committed logic's `step`, commits `new_root` under a FRESH caller-supplied
    /// `new_salt` (per-transition blinding rotation), and emits `{old_root, new_root, outputs}`.
    fn transition(
        ref self: TContractState,
        public_input: Array<felt252>,
        private_input: ShardState,
        new_salt: felt252,
    );

    /// ON-CHAIN — submitted with `{proof, proofFacts}`. Verifies the proof<->message
    /// binding and compare-and-swaps the anchored root. Logic-agnostic.
    fn apply_transition(ref self: TContractState, msg: PublicMessage);

    /// Current anchored commitment.
    fn get_root(self: @TContractState) -> felt252;
}

/// The pluggable logic interface. Any DECLARED class implementing this can govern a
/// shard (declaring is public — you hide which logic a shard uses, not the code).
///
/// `step` MUST be a pure state transition: it must not touch storage and must not
/// emit L2->L1 messages (the framework is the sole emitter; a logic that emits makes
/// `proof_facts[7] != 1` and the transition fails closed).
///
/// It returns its chosen successor `logic_class_hash`. Return the SAME hash to
/// self-perpetuate; return a DIFFERENT one to upgrade. A logic that always returns
/// its own hash is permanently immutable (a one-way ratchet) — this is how logics
/// self-govern their own mutability.
#[starknet::interface]
pub trait ILogic<TContractState> {
    fn step(
        self: @TContractState,
        logic_class_hash: felt252,
        app_state: Array<felt252>,
        public_input: Array<felt252>,
    ) -> (felt252, Array<felt252>, Array<felt252>);
}
