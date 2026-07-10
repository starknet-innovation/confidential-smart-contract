//! da_kit — in-circuit encrypted data-availability for confidential logics.
//!
//! Reusable, importable module (stateless) layered on `crypto_kit` (the audited STARK-curve
//! ECIES primitive). A logic calls `seal` inside `step` to turn its successor `app_state`
//! into an opaque `outputs` blob encrypted to every party's key; the framework publishes it
//! in the `Transitioned` event. Because the ciphertext is COMPUTED in `step`, the SNIP-36
//! proof guarantees it really is the committed state — so a MALICIOUS operator cannot
//! broadcast garbage (the availability hole that a plain echoed cipher leaves open).
//!
//! Use this instead of `salt_kit` when a resuming party is BLIND to committed state (a
//! shared pool where a member can't reconstruct others' positions; third-party-verifiable
//! DA). When every party already knows the state modulo the blinding (e.g. lending), prefer
//! `salt_kit` — it's cheaper and needs no crypto.
//!
//! A party recovers the state off-chain (`orchestration/src/da.ts`) and MUST verify it by
//! checking `commit(state) == new_root` (the framework can't verify ciphertext↔state; the
//! party can, against the proven root).

use crate::crypto_kit;

/// Encrypt `state` to each party's public key (x-coords), returning the `outputs` blob a
/// logic's `step` publishes. `eph` is an ephemeral scalar (bind it to per-transition
/// randomness or derive it via `salt_kit::rotate`); `nonce` is the transition counter
/// (domain-separates keystreams). Recipient order MUST be stable — a party opens by index.
pub fn seal(
    state: Span<felt252>, party_pub_xs: Span<felt252>, eph: felt252, nonce: felt252,
) -> Array<felt252> {
    crypto_kit::ecies_encrypt(state, party_pub_xs, eph, nonce)
}

/// Recipient `index` recovers the state from a blob with their private scalar (reverts on a
/// bad tag). This is the Cairo mirror of the off-chain decrypt (used by tests); parties
/// normally open off-chain and check `commit(state) == new_root`.
pub fn open(blob: Span<felt252>, recipient_priv: felt252, index: u32, nonce: felt252) -> Array<felt252> {
    crypto_kit::ecies_decrypt(blob, recipient_priv, index, nonce)
}

/// x-coordinate of the public key for a private scalar — a recipient key (re-exported).
pub fn pubkey_x(priv: felt252) -> felt252 {
    crypto_kit::pubkey_x(priv)
}
