//! Public interface and shared types for the confidential counter shard.
//!
//! These types are the contract's data boundary. `PreState` is the confidential
//! off-chain state (never published); `PublicMessage` is the only thing the proof
//! commits to publicly and is re-supplied as calldata on-chain.

/// Full off-chain pre-state. Lives NOWHERE on-chain and is never published — it
/// is passed to the virtual `transition` as `private_input` only.
///
/// `salt` is a blinding factor so that `commit(PreState)` is *hiding*: the
/// on-chain `root` reveals nothing about `count`.
#[derive(Drop, Serde)]
pub struct PreState {
    pub count: felt252,
    pub salt: felt252,
}

/// Public action parameters — allowed to be visible.
#[derive(Drop, Serde)]
pub struct Action {
    pub step: felt252,
}

/// The public claim the proof commits to. Emitted as the virtual function's
/// single L2->L1 message payload, and re-supplied verbatim as calldata to the
/// on-chain `apply_transition`, which binds it to the proof via proof_facts.
#[derive(Drop, Serde, Copy)]
pub struct PublicMessage {
    pub old_root: felt252,
    pub new_root: felt252,
    pub step: felt252,
}

#[starknet::interface]
pub trait ICounterShard<TContractState> {
    /// VIRTUAL — proven off-chain inside the SNIP-36 prover, never meaningfully
    /// called on-chain. Emits `{old_root, new_root, step}` as an L2->L1 message.
    fn transition(ref self: TContractState, public_input: Action, private_input: PreState);

    /// ON-CHAIN — submitted as a v3 tx carrying `{proof, proofFacts}`. Verifies
    /// the proof<->message binding and compare-and-swaps the anchored root.
    fn apply_transition(ref self: TContractState, msg: PublicMessage);

    /// Current anchored commitment.
    fn get_root(self: @TContractState) -> felt252;
}
