//! PrivateRegister (da_kit example) tests: a transition SEALS the successor state to the
//! parties in-circuit, and each party recovers it by decrypting with their stark key — the
//! blind-party encrypted-DA case. Calls `step` directly (like the committee tests) to inspect
//! `outputs` (the sealed blob), then `da_kit::open`s it. Also checks the sealed state commits
//! to `new_root` (v5: poseidon(logic, app_state), no salt) — so a party can self-prove.

use snforge_std::{declare, ContractClassTrait, DeclareResultTrait};
use confidential_counter::interfaces::{ILogicDispatcher, ILogicDispatcherTrait};
use confidential_counter::crypto_kit::pubkey_x;
use confidential_counter::da_kit;
use core::poseidon::poseidon_hash_span;

fn deploy() -> ILogicDispatcher {
    let (addr, _) = declare("PrivateRegisterLogic").unwrap().contract_class().deploy(@array![]).unwrap();
    ILogicDispatcher { contract_address: addr }
}

/// v5 commitment: poseidon(logic_class_hash, app_state.len, ...app_state).
fn commit(logic: felt252, app_state: Span<felt252>) -> felt252 {
    let mut data: Array<felt252> = array![logic, app_state.len().into()];
    for x in app_state {
        data.append(*x);
    };
    poseidon_hash_span(data.span())
}

#[test]
fn seals_state_and_each_party_recovers_it() {
    let logic = deploy();
    let (priv_a, priv_b) = (0xA11CE, 0xB0B);
    let (key_a, key_b) = (pubkey_x(priv_a), pubkey_x(priv_b));

    // app_state = [nonce, value, seed, n=2, key_a, key_b]
    let app_state = array![0, 0x1111, 0x5EED, 2, key_a, key_b];
    let eph = 0x9999;
    let (next, new_state, outputs, actions) = logic.step(0x77, app_state, array![0x2222, eph]);

    assert(next == 0x77, 'self-perpetuates');
    assert(actions.len() == 0, 'no actions');
    // Successor = [nonce+1, new_value, seed, n, keys...]
    let expected = array![1, 0x2222, 0x5EED, 2, key_a, key_b];
    assert(new_state == expected, 'successor state');

    // Each party decrypts the sealed `outputs` and recovers the full successor state.
    let opened_a = da_kit::open(outputs.span(), priv_a, 0, 1);
    assert(opened_a == expected, 'party A recovers state');
    let opened_b = da_kit::open(outputs.span(), priv_b, 1, 1);
    assert(opened_b == expected, 'party B recovers state');

    // A party can now self-prove: the recovered state commits to what a v5 shard anchors.
    assert(commit(0x77, opened_a.span()) == commit(0x77, new_state.span()), 'recovered commits to root');
}

#[test]
#[should_panic(expected: 'bad tag')]
fn non_party_cannot_decrypt() {
    let logic = deploy();
    let (key_a, key_b) = (pubkey_x(0xA11CE), pubkey_x(0xB0B));
    let app_state = array![0, 0x1111, 0x5EED, 2, key_a, key_b];
    let (_next, _new_state, outputs, _actions) = logic.step(0x77, app_state, array![0x2222, 0x9999]);
    // An outsider's key yields a wrong shared secret → MAC rejects.
    da_kit::open(outputs.span(), 0xDEAD, 0, 1);
}
