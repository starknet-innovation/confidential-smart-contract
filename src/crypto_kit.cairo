//! In-circuit encrypted-DA crypto kit (SPIKE) — hybrid ECIES over the STARK curve.
//!
//! This is the crypto core of a future `da_kit`: a logic can call `ecies_encrypt` inside
//! `step` to publish its successor state ENCRYPTED to every party's key, with the SNIP-36
//! proof guaranteeing the ciphertext really is that state (defeating a malicious operator
//! who would otherwise broadcast garbage). NOT part of the frozen framework — an importable
//! logic component, like `logic_kit`.
//!
//! Construction (all STARK-native, cheap in-proof):
//!   KEM — ECDH via the native EC op: recipient key is a stark-curve public key (its
//!         x-coord suffices; ±y give the same shared-x, so `new_from_x` is fine). Shared
//!         secret S = eph·P; symmetric key = Poseidon(domain, S.x).
//!   DEM — Poseidon-CTR stream cipher (cⱼ = mⱼ + Poseidon(domain,key,nonce,j)) + a Poseidon
//!         MAC over the ciphertext (encrypt-then-MAC). `nonce` (the loan's transition nonce)
//!         domain-separates keystreams so a reused ephemeral can't cause a two-time pad.
//!
//! The recipients' keys ARE their Starknet account keys — the same stark curve used for
//! `is_valid_signature` — so no separate key management.

use core::ec::{EcPointTrait, NonZeroEcPoint, stark_curve};
use core::poseidon::poseidon_hash_span;

const KEY_DOMAIN: felt252 = 'CS-DA-KEY';
const CTR_DOMAIN: felt252 = 'CS-DA-CTR';
const MAC_DOMAIN: felt252 = 'CS-DA-MAC';

fn coords(p: core::ec::EcPoint) -> (felt252, felt252) {
    let nz: NonZeroEcPoint = p.try_into().unwrap();
    nz.coordinates()
}

/// x-coordinate of the public key for a private scalar (P = priv·G). A recipient key.
pub fn pubkey_x(priv: felt252) -> felt252 {
    let g = EcPointTrait::new(stark_curve::GEN_X, stark_curve::GEN_Y).unwrap();
    let (x, _) = coords(g.mul(priv));
    x
}

/// Ephemeral public R = eph·G, as (x, y). Published in the blob so recipients can derive S.
pub fn ephemeral_pub(eph: felt252) -> (felt252, felt252) {
    let g = EcPointTrait::new(stark_curve::GEN_X, stark_curve::GEN_Y).unwrap();
    coords(g.mul(eph))
}

/// Encryptor side: symmetric key for a recipient (their pubkey x-coord) + ephemeral `eph`.
pub fn shared_key_enc(recipient_pub_x: felt252, eph: felt252) -> felt252 {
    let p = EcPointTrait::new_from_x(recipient_pub_x).unwrap();
    let (sx, _) = coords(p.mul(eph));
    poseidon_hash_span(array![KEY_DOMAIN, sx].span())
}

/// Recipient side: same key from their private scalar and the ephemeral public R=(rx,ry).
pub fn shared_key_dec(recipient_priv: felt252, rx: felt252, ry: felt252) -> felt252 {
    let r = EcPointTrait::new(rx, ry).unwrap();
    let (sx, _) = coords(r.mul(recipient_priv));
    poseidon_hash_span(array![KEY_DOMAIN, sx].span())
}

fn keystream(key: felt252, nonce: felt252, j: felt252) -> felt252 {
    poseidon_hash_span(array![CTR_DOMAIN, key, nonce, j].span())
}

pub fn encrypt(key: felt252, nonce: felt252, msg: Span<felt252>) -> Array<felt252> {
    let mut ct: Array<felt252> = array![];
    let mut j: felt252 = 0;
    let mut i: u32 = 0;
    while i != msg.len() {
        ct.append(*msg.at(i) + keystream(key, nonce, j));
        j += 1;
        i += 1;
    };
    ct
}

pub fn decrypt(key: felt252, nonce: felt252, ct: Span<felt252>) -> Array<felt252> {
    let mut msg: Array<felt252> = array![];
    let mut j: felt252 = 0;
    let mut i: u32 = 0;
    while i != ct.len() {
        msg.append(*ct.at(i) - keystream(key, nonce, j));
        j += 1;
        i += 1;
    };
    msg
}

pub fn mac(key: felt252, nonce: felt252, ct: Span<felt252>) -> felt252 {
    let mut data: Array<felt252> = array![MAC_DOMAIN, key, nonce];
    for c in ct {
        data.append(*c);
    };
    poseidon_hash_span(data.span())
}

/// Encrypt `msg` to each recipient pubkey (x-coords), in order. Blob layout:
///   [rx, ry, n_recipients, msg_len, {ct[0..len], tag} per recipient].
pub fn ecies_encrypt(
    msg: Span<felt252>, recipient_pub_xs: Span<felt252>, eph: felt252, nonce: felt252,
) -> Array<felt252> {
    let (rx, ry) = ephemeral_pub(eph);
    let mut out: Array<felt252> = array![rx, ry, recipient_pub_xs.len().into(), msg.len().into()];
    let mut i: u32 = 0;
    while i != recipient_pub_xs.len() {
        let key = shared_key_enc(*recipient_pub_xs.at(i), eph);
        let ct = encrypt(key, nonce, msg);
        let tag = mac(key, nonce, ct.span());
        for c in ct.span() {
            out.append(*c);
        };
        out.append(tag);
        i += 1;
    };
    out
}

/// Recipient `index` decrypts the blob with their private scalar. Reverts on a bad tag.
pub fn ecies_decrypt(
    blob: Span<felt252>, recipient_priv: felt252, index: u32, nonce: felt252,
) -> Array<felt252> {
    let rx = *blob.at(0);
    let ry = *blob.at(1);
    let len: u32 = (*blob.at(3)).try_into().unwrap();
    let key = shared_key_dec(recipient_priv, rx, ry);
    let base = 4 + index * (len + 1);
    let mut ct: Array<felt252> = array![];
    let mut k: u32 = 0;
    while k != len {
        ct.append(*blob.at(base + k));
        k += 1;
    };
    assert(mac(key, nonce, ct.span()) == *blob.at(base + len), 'bad tag');
    decrypt(key, nonce, ct.span())
}
