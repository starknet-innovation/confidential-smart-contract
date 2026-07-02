//! Reference pluggable logic classes for the confidential shard framework.
//!
//! `CounterLogic` is a minimal, IMMUTABLE dummy example implementing `ILogic::step`. A
//! shard commits to it by class hash inside its state; the framework `library_call`s it.
//! No reference logic ships an upgrade path — upgradeable logics must gate their own
//! successor choice (see DESIGN.md / audit finding #2).

pub mod counter_logic;
