//! Confidential counter shard — a minimal SNIP-36 confidential smart contract.
//!
//! State (a counter) lives OFF-CHAIN and is published nowhere. On-chain we hold
//! only a single Poseidon commitment (`root`) and advance it by verifying proofs
//! of off-chain state transitions. See DESIGN.md for the full architecture.

pub mod interfaces;
pub mod contract;
