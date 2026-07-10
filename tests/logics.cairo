//! Unit tests for the reference logics' `step` — pure, immutable state transitions.
//! `CounterLogic` has no side effects; `CommitteeLogic` verifies threshold SNIP-12
//! approvals via each member account's `is_valid_signature` (AA-native) IN-PROOF and
//! emits the approved calls as outbox actions. Members are `MockAccount`s; the tests
//! sign the SNIP-12 hash the logic computes. (When `step` is called directly like this,
//! `get_contract_address()` inside the logic is the LOGIC's own address; the tests
//! mirror that as the `shard` field of the approval.)

use snforge_std::{
    declare, ContractClassTrait, DeclareResultTrait, start_cheat_chain_id_global,
};
use snforge_std::signature::KeyPairTrait;
use snforge_std::signature::stark_curve::{StarkCurveKeyPairImpl, StarkCurveSignerImpl};
use confidential_counter::interfaces::{ILogicDispatcher, ILogicDispatcherTrait, PublicCall};
use confidential_counter::logics::committee_logic::{MemberSig, CommitteeLogic};
use core::poseidon::poseidon_hash_span;
use starknet::ContractAddress;

/// Known chain_id the tests pin so signing matches `get_tx_info()` inside the logic.
const TEST_CHAIN_ID: felt252 = 'TESTCHAIN';

fn deploy(name: ByteArray) -> ILogicDispatcher {
    let contract = declare(name).unwrap().contract_class();
    let (addr, _) = contract.deploy(@array![]).unwrap();
    ILogicDispatcher { contract_address: addr }
}

/// Deploy a SNIP-6 MockAccount holding `public_key`; returns its address (a committee member).
fn deploy_member(public_key: felt252) -> ContractAddress {
    let cls = declare("MockAccount").unwrap().contract_class();
    let (addr, _) = cls.deploy(@array![public_key]).unwrap();
    addr
}

#[test]
fn counter_increments_and_self_perpetuates() {
    let logic = deploy("CounterLogic");
    let (next, new_state, outputs, actions) = logic.step(0x123, array![5], array![3]);
    assert(next == 0x123, 'should keep own logic hash');
    assert(new_state.len() == 1, 'app_state len');
    assert(*new_state.at(0) == 8, 'count should be 8');
    assert(*outputs.at(0) == 3, 'output should be step');
    assert(actions.len() == 0, 'counter emits no actions');
}

#[test]
fn counter_is_immutable_ignores_upgrade_directive() {
    let logic = deploy("CounterLogic");
    // Even with an extra "upgrade" arg in public_input, the immutable dummy returns its
    // OWN class hash — it has no upgrade path.
    let (next, new_state, _, _) = logic.step(0xABC, array![5], array![3, 0x999]);
    assert(next == 0xABC, 'must stay immutable');
    assert(*new_state.at(0) == 8, 'count still advances');
}

#[test]
#[should_panic]
fn counter_reverts_on_u128_overflow() {
    let logic = deploy("CounterLogic");
    // u128::MAX + 1 must panic (no felt252 wraparound) — addresses audit finding #1.
    logic.step(0x1, array![0xffffffffffffffffffffffffffffffff], array![1]);
}

// ---------------------------------------------------------------------------
// CommitteeLogic
// ---------------------------------------------------------------------------

/// One arbitrary proposal (an ERC-20-transfer-shaped call).
fn mk_calls() -> Array<PublicCall> {
    array![
        PublicCall {
            to: 0xDEAD_felt252.try_into().unwrap(),
            selector: selector!("transfer"),
            calldata: array![0xBEEF, 10, 0],
        },
    ]
}

/// poseidon(Serde(calls)) — mirror of the logic's calls_hash.
fn calls_hash(calls: @Array<PublicCall>) -> felt252 {
    let mut d: Array<felt252> = array![];
    calls.serialize(ref d);
    poseidon_hash_span(d.span())
}

/// Build one member's SNIP-12 approval: compute the exact hash the logic will verify
/// (via the logic's own `approval_message_hash`) and sign it with the member's key.
/// The chain_id must already be cheated to the value the logic will read.
fn approve(
    kp: snforge_std::signature::KeyPair<felt252, felt252>,
    member: ContractAddress,
    shard: ContractAddress,
    nonce: felt252,
    calls: @Array<PublicCall>,
) -> MemberSig {
    let hash = CommitteeLogic::approval_message_hash(shard.into(), nonce, calls_hash(calls), member);
    let (r, s) = kp.sign(hash).unwrap();
    MemberSig { signer: member, signature: array![r, s] }
}

/// public_input = Serde(calls) ++ Serde(Array<MemberSig>).
fn mk_public_input(calls: @Array<PublicCall>, sigs: Array<MemberSig>) -> Array<felt252> {
    let mut pi: Array<felt252> = array![];
    calls.serialize(ref pi);
    sigs.serialize(ref pi);
    pi
}

/// The Cairo SNIP-12 approval hash must equal starknet.js `typedData.getMessageHash`
/// for the same inputs, or every off-chain-signed approval would be rejected on-chain.
/// The expected value is pinned from starknet.js (see orchestration/src/examples/committee.ts).
#[test]
fn approval_hash_matches_offchain_snip12() {
    start_cheat_chain_id_global('SN_SEPOLIA');
    let shard: felt252 = 0x6bb61654c22e728c5efc9ed74053e4b7caaedb5e43e08ae445b4507f2bbd36;
    let signer: ContractAddress = 0x1234.try_into().unwrap();
    let h = CommitteeLogic::approval_message_hash(shard, 5, 0xabc, signer);
    assert(h == 0x94ebc827404e59db9147d33e976e3bab805e36273fb5ff22ca80cb20d552fa, 'snip12 mismatch');
}

#[test]
fn committee_executes_threshold_approved_calls() {
    start_cheat_chain_id_global(TEST_CHAIN_ID);
    let logic = deploy("CommitteeLogic");
    let shard = logic.contract_address;
    let kp1 = KeyPairTrait::<felt252, felt252>::generate();
    let kp2 = KeyPairTrait::<felt252, felt252>::generate();
    let kp3 = KeyPairTrait::<felt252, felt252>::generate();
    let m1 = deploy_member(kp1.public_key);
    let m2 = deploy_member(kp2.public_key);
    let m3 = deploy_member(kp3.public_key);
    // v5 app_state = [nonce=0, threshold=2, n=3, members..., seed] (trailing salt_kit blinding)
    let app_state = array![0, 2, 3, m1.into(), m2.into(), m3.into(), 0x5EED];

    let calls = mk_calls();
    let sigs = array![
        approve(kp1, m1, shard, 0, @calls), approve(kp2, m2, shard, 0, @calls),
    ];

    let (next, new_state, outputs, actions) = logic
        .step(0x77, app_state, mk_public_input(@calls, sigs));

    assert(next == 0x77, 'committee self-perpetuates');
    assert(*new_state.at(0) == 1, 'nonce advanced');
    assert(*new_state.at(1) == 2, 'threshold kept');
    assert(*new_state.at(2) == 3, 'members kept');
    assert(*new_state.at(3) == m1.into(), 'member 1 kept');
    assert(outputs.len() == 0, 'no public outputs');
    assert(actions.len() == 1, 'one action');
    let a = actions.at(0);
    assert((*a.to).into() == 0xDEAD_felt252, 'action target');
    assert(*a.selector == selector!("transfer"), 'action selector');
    assert(*a.calldata.at(0) == 0xBEEF, 'action calldata');
}

#[test]
#[should_panic(expected: 'threshold not met')]
fn committee_rejects_below_threshold() {
    start_cheat_chain_id_global(TEST_CHAIN_ID);
    let logic = deploy("CommitteeLogic");
    let shard = logic.contract_address;
    let kp1 = KeyPairTrait::<felt252, felt252>::generate();
    let kp2 = KeyPairTrait::<felt252, felt252>::generate();
    let m1 = deploy_member(kp1.public_key);
    let m2 = deploy_member(kp2.public_key);
    let app_state = array![0, 2, 2, m1.into(), m2.into(), 0x5EED];

    let calls = mk_calls();
    let sigs = array![approve(kp1, m1, shard, 0, @calls)]; // 1 sig, threshold 2
    logic.step(0x77, app_state, mk_public_input(@calls, sigs));
}

#[test]
#[should_panic(expected: 'duplicate signer')]
fn committee_rejects_duplicate_signer() {
    start_cheat_chain_id_global(TEST_CHAIN_ID);
    let logic = deploy("CommitteeLogic");
    let shard = logic.contract_address;
    let kp1 = KeyPairTrait::<felt252, felt252>::generate();
    let kp2 = KeyPairTrait::<felt252, felt252>::generate();
    let m1 = deploy_member(kp1.public_key);
    let m2 = deploy_member(kp2.public_key);
    let app_state = array![0, 2, 2, m1.into(), m2.into(), 0x5EED];

    let calls = mk_calls();
    // Same member twice must not reach the threshold.
    let sigs = array![
        approve(kp1, m1, shard, 0, @calls), approve(kp1, m1, shard, 0, @calls),
    ];
    logic.step(0x77, app_state, mk_public_input(@calls, sigs));
}

#[test]
#[should_panic(expected: 'not a member')]
fn committee_rejects_non_member() {
    start_cheat_chain_id_global(TEST_CHAIN_ID);
    let logic = deploy("CommitteeLogic");
    let shard = logic.contract_address;
    let kp1 = KeyPairTrait::<felt252, felt252>::generate();
    let outsider = KeyPairTrait::<felt252, felt252>::generate();
    let m1 = deploy_member(kp1.public_key);
    let out_addr = deploy_member(outsider.public_key);
    let app_state = array![0, 1, 1, m1.into(), 0x5EED]; // only m1 is a member (+ seed)

    let calls = mk_calls();
    let sigs = array![approve(outsider, out_addr, shard, 0, @calls)];
    logic.step(0x77, app_state, mk_public_input(@calls, sigs));
}

#[test]
#[should_panic(expected: 'bad signature')]
fn committee_rejects_stale_nonce_approval() {
    start_cheat_chain_id_global(TEST_CHAIN_ID);
    let logic = deploy("CommitteeLogic");
    let shard = logic.contract_address;
    let kp1 = KeyPairTrait::<felt252, felt252>::generate();
    let m1 = deploy_member(kp1.public_key);
    // State is at nonce 1; the approval was signed for nonce 0 (a replay).
    let app_state = array![1, 1, 1, m1.into(), 0x5EED];

    let calls = mk_calls();
    let sigs = array![approve(kp1, m1, shard, 0, @calls)]; // signed for nonce 0
    logic.step(0x77, app_state, mk_public_input(@calls, sigs));
}

#[test]
#[should_panic(expected: 'bad signature')]
fn committee_rejects_cross_chain_replay() {
    // An approval signed for one chain must not verify on another identically-addressed
    // shard: sign under CHAIN_A, run the logic under CHAIN_B; the SNIP-12 domain differs
    // (chainId), so the recomputed hash differs -> is_valid_signature rejects it.
    let logic = deploy("CommitteeLogic");
    let shard = logic.contract_address;
    let kp1 = KeyPairTrait::<felt252, felt252>::generate();
    let m1 = deploy_member(kp1.public_key);
    let app_state = array![0, 1, 1, m1.into(), 0x5EED];
    let calls = mk_calls();

    start_cheat_chain_id_global('CHAIN_A');
    let sigs = array![approve(kp1, m1, shard, 0, @calls)]; // signed under CHAIN_A

    start_cheat_chain_id_global('CHAIN_B'); // logic now runs under CHAIN_B
    logic.step(0x77, app_state, mk_public_input(@calls, sigs));
}
