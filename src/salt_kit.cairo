//! salt_kit — malicious-operator-safe deterministic blinding for confidential logics.
//!
//! Reusable, importable, and stateless (a module, not a component — there's no storage: the
//! blinding lives in the logic's own `app_state`). The pattern:
//!
//!   • Keep a high-entropy `seed` in `app_state` — it IS the blinding. Hiding vs the public
//!     comes from the seed being secret; the monotonic transition `nonce` (also in app_state)
//!     guarantees every `new_root` is unique (no preimage reuse).
//!   • Pass the framework's `new_salt` as the PUBLIC constant `SALT` (non-zero, so the
//!     framework's guard passes). The framework salt no longer carries any secrecy — the
//!     seed does.
//!   • `step` carries the seed forward unchanged (proven), so an operator cannot deviate it.
//!
//! Why this is malicious-operator-safe (not just absent-operator-safe): the committed state
//! is a deterministic function of (logic, agreed terms, public events, the fixed seed, the
//! nonce) — the only inputs. Because the seed is committed + carried by the proof and the
//! framework salt is a public constant, ANY party who knows the seed (established at
//! origination, e.g. a 3-way key exchange) can reconstruct every state and self-prove — the
//! operator can neither withhold nor corrupt what's needed. No cipher, no in-circuit crypto.
//!
//! This works when the resuming party already knows the app_state modulo the blinding (e.g.
//! lending: the parties agreed the terms). When a party is BLIND to committed state, you
//! need `da_kit` (encrypted DA) instead.
//!
//! `rotate` derives a distinct per-transition value from the seed — for logics that prefer a
//! rotating blinding FIELD (so recovering one transition's blinding, without the seed, leaks
//! nothing about others), or that need per-transition secrets (e.g. a `da_kit` ephemeral).

use core::poseidon::poseidon_hash_span;

const DOMAIN: felt252 = 'SALT-KIT';

/// The public constant a salt_kit logic passes as the framework's `new_salt`.
/// Non-zero (the framework rejects a zero salt); carries no secrecy — the seed does.
pub const SALT: felt252 = 1;

/// Deterministic per-transition value derived from a committed `seed` and `nonce`.
/// Pseudorandom to anyone without `seed`; identical for every party who holds it.
pub fn rotate(seed: felt252, nonce: felt252) -> felt252 {
    poseidon_hash_span(array![DOMAIN, seed, nonce].span())
}
