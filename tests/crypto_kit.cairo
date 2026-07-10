//! Spike tests for the in-circuit encrypted-DA crypto (src/crypto_kit.cairo): STARK-curve
//! ECDH key agreement is consistent between encryptor and recipient, the Poseidon DEM
//! round-trips, the MAC rejects tampering and wrong keys, multi-recipient works, and a
//! realistic-size encryption's l2_gas (the [PASS] line) anchors the in-circuit cost.

use confidential_counter::crypto_kit::{
    pubkey_x, shared_key_enc, shared_key_dec, ephemeral_pub, ecies_encrypt, ecies_decrypt,
};

#[test]
fn ecdh_key_agreement_is_consistent() {
    // Encryptor derives from (recipient pubkey x, eph); recipient from (priv, eph·G). Equal.
    let priv = 0xA1F00D;
    let px = pubkey_x(priv);
    let eph = 0x1234BEEF;
    let (rx, ry) = ephemeral_pub(eph);
    assert(shared_key_enc(px, eph) == shared_key_dec(priv, rx, ry), 'ecdh mismatch');
}

#[test]
fn ecies_round_trips() {
    let priv = 0xB0B5EC;
    let px = pubkey_x(priv);
    let msg = array![0x11, 0x22, 0x33, 0x44];
    let blob = ecies_encrypt(msg.span(), array![px].span(), 0x9999, 7);
    let dec = ecies_decrypt(blob.span(), priv, 0, 7);
    assert(dec == msg, 'round-trip mismatch');
}

#[test]
fn multi_recipient_each_decrypts() {
    let (p1, p2, p3) = (0xA1, 0xB2, 0xC3);
    let msg = array![0xDEAD, 0xBEEF, 0xCAFE];
    let recips = array![pubkey_x(p1), pubkey_x(p2), pubkey_x(p3)];
    let blob = ecies_encrypt(msg.span(), recips.span(), 0x5A17, 3);
    assert(ecies_decrypt(blob.span(), p1, 0, 3) == msg, 'r1');
    assert(ecies_decrypt(blob.span(), p2, 1, 3) == msg, 'r2');
    assert(ecies_decrypt(blob.span(), p3, 2, 3) == msg, 'r3');
}

#[test]
#[should_panic(expected: 'bad tag')]
fn rejects_tampered_ciphertext() {
    let priv = 0xB2;
    let blob = ecies_encrypt(array![0x11, 0x22].span(), array![pubkey_x(priv)].span(), 0x1, 1);
    // Flip a ciphertext felt (index 4 = first ct felt after the [rx,ry,n,len] header).
    let mut bad: Array<felt252> = array![];
    let mut i: u32 = 0;
    while i != blob.len() {
        if i == 4 {
            bad.append(*blob.at(i) + 1);
        } else {
            bad.append(*blob.at(i));
        }
        i += 1;
    };
    ecies_decrypt(bad.span(), priv, 0, 1);
}

#[test]
#[should_panic(expected: 'bad tag')]
fn rejects_wrong_key() {
    let blob = ecies_encrypt(array![0x11, 0x22].span(), array![pubkey_x(0xB2)].span(), 0x1, 1);
    ecies_decrypt(blob.span(), 0xDEAD, 0, 1); // wrong private scalar → wrong key → bad tag
}

#[test]
fn dump_blob_for_interop() {
    // Fixed test vector for the Cairo→TS interop check (orchestration/_ci.ts decrypts it).
    let priv = 0xB0B5EC;
    let msg = array![0x11, 0x22, 0x33, 0x44];
    let blob = ecies_encrypt(msg.span(), array![pubkey_x(priv)].span(), 0x9999, 7);
    println!("INTEROP recipient_pub_x={}", pubkey_x(priv));
    let mut i: u32 = 0;
    while i != blob.len() {
        println!("INTEROP blob[{}]={}", i, *blob.at(i));
        i += 1;
    };
}

#[test]
fn realistic_state_cost() {
    // 20-felt state (a lending app_state) to 3 parties — the real step-side cost. The [PASS]
    // l2_gas line is the anchor for whether in-circuit DA is affordable.
    let mut msg: Array<felt252> = array![];
    let mut i: felt252 = 0;
    let mut k: u32 = 0;
    while k != 20 {
        msg.append(i * 7 + 3);
        i += 1;
        k += 1;
    };
    let recips = array![pubkey_x(0xA1), pubkey_x(0xB2), pubkey_x(0xC3)];
    let blob = ecies_encrypt(msg.span(), recips.span(), 0xEEEE, 42);
    // header 4 + 3*(20+1) = 67 felts
    assert(blob.len() == 67, 'blob size');
}
