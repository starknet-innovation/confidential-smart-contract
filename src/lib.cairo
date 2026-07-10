//! Confidential shard framework — a generic SNIP-36 confidential smart contract.
//!
//! State lives OFF-CHAIN and is published nowhere; on-chain holds only a single
//! Poseidon commitment (`root`). The state transition is computed off-chain by a
//! PLUGGABLE logic class named by `logic_class_hash` — which itself lives inside the
//! committed state, so which logic governs a shard is confidential and self-enforcing.
//! Logics self-govern their own upgrades (and their own immutability). See DESIGN.md.

pub mod interfaces;
pub mod shard_component;
pub mod framework;
pub mod logic_kit;
pub mod salt_kit;
pub mod crypto_kit;
pub mod da_kit;
pub mod logics;
pub mod mocks;
