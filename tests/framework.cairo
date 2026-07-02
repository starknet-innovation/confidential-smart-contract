//! Framework-level test: `transition` library_calls the committed logic and emits an
//! L2->L1 message = Serde(PublicMessage{old_root, new_root, outputs}). This exercises
//! `commit` (determinism + the logic_class_hash-in-commitment layout), the dispatch, and
//! per-transition salt rotation (new_root commits under the caller-supplied `new_salt`).
//!
//! (apply_transition's proof_facts path is only reachable on a live SNIP-36 sequencer —
//! verified for v1 on Sepolia — so it isn't unit-tested here; the off-chain SDK
//! `checkProof` mirrors compute_message_hash for the pre-broadcast gate.)

use snforge_std::{
    declare, ContractClassTrait, DeclareResultTrait, spy_messages_to_l1,
    MessageToL1SpyAssertionsTrait, MessageToL1,
};
use confidential_counter::interfaces::{IShardDispatcher, IShardDispatcherTrait, ShardState};
use core::poseidon::poseidon_hash_span;

fn commit(logic_class_hash: felt252, app_state: Span<felt252>, salt: felt252) -> felt252 {
    let mut data: Array<felt252> = array![logic_class_hash, app_state.len().into()];
    for x in app_state {
        data.append(*x);
    };
    data.append(salt);
    poseidon_hash_span(data.span())
}

fn deploy_shard() -> IShardDispatcher {
    // transition() doesn't read `root`, so genesis can be anything nonzero.
    let fw = declare("ConfidentialShard").unwrap().contract_class();
    let (addr, _) = fw.deploy(@array![0x1]).unwrap();
    IShardDispatcher { contract_address: addr }
}

fn logic_hash(name: ByteArray) -> felt252 {
    let cc = declare(name).unwrap().contract_class();
    (*cc.class_hash).into()
}

#[test]
fn transition_emits_committed_message_with_rotated_salt() {
    let logic_class_hash = logic_hash("CounterLogic");
    let shard = deploy_shard();

    let salt = 42;
    let new_salt = 999; // caller-supplied fresh blinding for the successor state
    let state = ShardState { logic_class_hash, app_state: array![5], salt };

    let expected_old = commit(logic_class_hash, array![5].span(), salt);
    let expected_new = commit(logic_class_hash, array![8].span(), new_salt); // 5 + step 3, NEW salt

    // Sanity: new_root must NOT reuse the old salt (that's the whole fix).
    assert(expected_new != commit(logic_class_hash, array![8].span(), salt), 'salt not rotated');

    let mut spy = spy_messages_to_l1();
    shard.transition(array![3], state, new_salt);

    spy
        .assert_sent(
            @array![
                (
                    shard.contract_address,
                    MessageToL1 {
                        to_address: 0_felt252.try_into().unwrap(),
                        payload: array![expected_old, expected_new, 1, 3],
                    },
                ),
            ],
        );
}

#[test]
fn transition_keeps_logic_immutable_despite_extra_public_input() {
    let logic_class_hash = logic_hash("CounterLogic");
    let shard = deploy_shard();

    let salt = 7;
    let new_salt = 123;
    let state = ShardState { logic_class_hash, app_state: array![10], salt };

    let expected_old = commit(logic_class_hash, array![10].span(), salt);
    // CounterLogic is immutable: even with an extra "upgrade" arg in public_input, new_root
    // commits the SAME logic class hash (not 0x999) + advanced count + rotated salt.
    let expected_new = commit(logic_class_hash, array![12].span(), new_salt); // 10 + step 2

    let mut spy = spy_messages_to_l1();
    shard.transition(array![2, 0x999], state, new_salt); // extra arg is ignored by the logic

    spy
        .assert_sent(
            @array![
                (
                    shard.contract_address,
                    MessageToL1 {
                        to_address: 0_felt252.try_into().unwrap(),
                        payload: array![expected_old, expected_new, 1, 2],
                    },
                ),
            ],
        );
}

#[test]
#[should_panic]
fn transition_rejects_zero_new_salt() {
    let logic_class_hash = logic_hash("CounterLogic");
    let shard = deploy_shard();
    let state = ShardState { logic_class_hash, app_state: array![5], salt: 42 };
    // A zero successor salt (no blinding) must be rejected by the framework guard.
    shard.transition(array![3], state, 0);
}
