//! Reference pluggable logic classes for the confidential shard framework.
//!
//! `CounterLogic` is a minimal, IMMUTABLE dummy example implementing `ILogic::step`. A
//! shard commits to it by class hash inside its state; the framework `library_call`s it.
//! `CommitteeLogic` is THE outbox reference: a confidential M-of-N committee whose
//! threshold-approved decisions emit arbitrary public calls (signatures verified
//! in-proof, never published).
//! No reference logic ships an upgrade path — upgradeable logics must gate their own
//! successor choice (see DESIGN.md / audit finding #2).

pub mod committee_logic;
pub mod counter_logic;
pub mod lending_logic;
pub mod register_logic;
pub mod template_logic;
