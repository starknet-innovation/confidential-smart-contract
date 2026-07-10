//! Framework-level tests:
//!  - `transition` library_calls the committed logic and emits an L2->L1 message =
//!    Serde(PublicMessage{old_root, new_root, outputs, actions}). Exercises `commit`
//!    (determinism + the logic_class_hash-in-commitment layout), the dispatch, and
//!    per-transition salt rotation (new_root commits under the caller-supplied `new_salt`).
//!  - `consume` executes a recorded outbox bundle exactly once, with a hash guard and a
//!    self-call guard; `outbox_of` observes record → consumed.
//!  - v4 inbox: `deposit` (framework-executed transfer_from) and `register_intent`
//!    append; `inbox_len`/`inbox_entry` read back; payload cap + intent fee enforced.
//!
//! `apply_transition`'s proof_facts path (incl. the freshness gate) is only reachable
//! on a live SNIP-36 sequencer (verified for v1 on Sepolia), so it isn't unit-tested
//! here — the off-chain SDK `checkProof` mirrors compute_message_hash for the
//! pre-broadcast gate. Since we can't call apply_transition in snforge, we seed the
//! outbox directly with `store` + `map_entry_address` to test `consume` (exactly what
//! apply_transition would have written).

use snforge_std::{
    declare, ContractClassTrait, DeclareResultTrait, spy_messages_to_l1,
    MessageToL1SpyAssertionsTrait, MessageToL1, store, map_entry_address,
    start_cheat_caller_address, stop_cheat_caller_address, start_cheat_chain_id_global,
};
use snforge_std::signature::KeyPairTrait;
use snforge_std::signature::stark_curve::{StarkCurveKeyPairImpl, StarkCurveSignerImpl};
use confidential_counter::interfaces::{
    IShardDispatcher, IShardDispatcherTrait, ShardState, PublicCall, INBOX_KIND_DEPOSIT,
    INBOX_KIND_INTENT,
};
use confidential_counter::logics::committee_logic::{MemberSig, CommitteeLogic};
use confidential_counter::mocks::erc20_mock::{IMockERC20Dispatcher, IMockERC20DispatcherTrait};
use core::poseidon::poseidon_hash_span;
use starknet::ContractAddress;

/// Known chain_id the tests pin so the approval-hash mirror matches `get_tx_info()`.
const TEST_CHAIN_ID: felt252 = 'TESTCHAIN';

fn commit(logic_class_hash: felt252, app_state: Span<felt252>) -> felt252 {
    let mut data: Array<felt252> = array![logic_class_hash, app_state.len().into()];
    for x in app_state {
        data.append(*x);
    };
    poseidon_hash_span(data.span())
}

/// Mirror of ConfidentialShard::hash_actions — poseidon(Serde(Array<PublicCall>)).
fn hash_actions(actions: @Array<PublicCall>) -> felt252 {
    let mut data: Array<felt252> = array![];
    actions.serialize(ref data);
    poseidon_hash_span(data.span())
}

/// poseidon(Serde(calls)) — mirror of the committee logic's calls_hash.
fn calls_hash(calls: @Array<PublicCall>) -> felt252 {
    let mut d: Array<felt252> = array![];
    calls.serialize(ref d);
    poseidon_hash_span(d.span())
}

/// Deploy a SNIP-6 MockAccount (committee member) holding `public_key`.
fn deploy_member(public_key: felt252) -> ContractAddress {
    let cls = declare("MockAccount").unwrap().contract_class();
    let (addr, _) = cls.deploy(@array![public_key]).unwrap();
    addr
}

/// One member's SNIP-12 approval, signed for the hash the committee logic will compute.
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

/// Constructor: (genesis_root, freshness_window=0, intent_fee_token=0, intent_fee=0).
/// transition() doesn't read `root`, so genesis can be anything nonzero.
fn deploy_shard() -> IShardDispatcher {
    deploy_shard_with(0, 0_felt252.try_into().unwrap(), 0_u256)
}

fn deploy_shard_with(
    freshness_window: u64, fee_token: ContractAddress, fee_amount: u256,
) -> IShardDispatcher {
    let fw = declare("ConfidentialShard").unwrap().contract_class();
    let calldata = array![
        0x1, // genesis_root
        freshness_window.into(),
        fee_token.into(),
        fee_amount.low.into(),
        fee_amount.high.into(),
    ];
    let (addr, _) = fw.deploy(@calldata).unwrap();
    IShardDispatcher { contract_address: addr }
}

fn deploy_mock_erc20(balance: u256) -> IMockERC20Dispatcher {
    let contract = declare("MockERC20").unwrap().contract_class();
    let (addr, _) = contract.deploy(@array![balance.low.into(), balance.high.into()]).unwrap();
    IMockERC20Dispatcher { contract_address: addr }
}

fn logic_hash(name: ByteArray) -> felt252 {
    let cc = declare(name).unwrap().contract_class();
    (*cc.class_hash).into()
}

/// Seed the outbox exactly as apply_transition would (key = new_root, value = actions_hash).
fn seed_outbox(shard: IShardDispatcher, entry_key: felt252, actions_hash: felt252) {
    store(
        shard.contract_address,
        map_entry_address(selector!("outbox"), array![entry_key].span()),
        array![actions_hash].span(),
    );
}

// ---------------------------------------------------------------------------
// transition (virtual dispatch + commitment) — v5: no framework salt
// ---------------------------------------------------------------------------

#[test]
fn transition_emits_committed_message() {
    let logic_class_hash = logic_hash("CounterLogic");
    let shard = deploy_shard();

    // v5: commitment = poseidon(logic, app_state); no framework salt. CounterLogic is a
    // transparent (opt-out) example — it keeps no blinding field.
    let state = ShardState { logic_class_hash, app_state: array![5] };
    let expected_old = commit(logic_class_hash, array![5].span());
    let expected_new = commit(logic_class_hash, array![8].span()); // 5 + step 3

    let mut spy = spy_messages_to_l1();
    shard.transition(array![3], state);

    // payload = [old, new, outputs.len, ...outputs, actions.len]. CounterLogic: outputs=[3].
    spy
        .assert_sent(
            @array![
                (
                    shard.contract_address,
                    MessageToL1 {
                        to_address: 0_felt252.try_into().unwrap(),
                        payload: array![expected_old, expected_new, 1, 3, 0],
                    },
                ),
            ],
        );
}

#[test]
fn transition_keeps_logic_immutable_despite_extra_public_input() {
    let logic_class_hash = logic_hash("CounterLogic");
    let shard = deploy_shard();

    let state = ShardState { logic_class_hash, app_state: array![10] };
    let expected_old = commit(logic_class_hash, array![10].span());
    // Immutable: even with an extra "upgrade" arg, new_root commits the SAME logic class hash.
    let expected_new = commit(logic_class_hash, array![12].span()); // 10 + step 2

    let mut spy = spy_messages_to_l1();
    shard.transition(array![2, 0x999], state); // extra arg ignored by the logic

    spy
        .assert_sent(
            @array![
                (
                    shard.contract_address,
                    MessageToL1 {
                        to_address: 0_felt252.try_into().unwrap(),
                        payload: array![expected_old, expected_new, 1, 2, 0],
                    },
                ),
            ],
        );
}

#[test]
fn transition_dispatches_committee_and_carries_actions() {
    // End-to-end virtual dispatch of the committee reference: threshold approvals are
    // verified in-proof (signed over the SHARD address, since library_call runs the
    // logic in the shard's context) and the approved calls ride in the proven message.
    start_cheat_chain_id_global(TEST_CHAIN_ID);
    let logic_class_hash = logic_hash("CommitteeLogic");
    let shard = deploy_shard();

    let kp1 = KeyPairTrait::<felt252, felt252>::generate();
    let kp2 = KeyPairTrait::<felt252, felt252>::generate();
    let kp3 = KeyPairTrait::<felt252, felt252>::generate();
    let m1 = deploy_member(kp1.public_key);
    let m2 = deploy_member(kp2.public_key);
    let m3 = deploy_member(kp3.public_key);
    let members = array![m1.into(), m2.into(), m3.into()];

    let calls = array![
        PublicCall {
            to: 0xDEAD_felt252.try_into().unwrap(),
            selector: selector!("transfer"),
            calldata: array![0xBEEF, 10, 0],
        },
    ];
    // Members 1 and 3 approve; signed over the SHARD address (library_call context).
    let sigs = array![
        approve(kp1, m1, shard.contract_address, 0, @calls),
        approve(kp3, m3, shard.contract_address, 0, @calls),
    ];
    let mut public_input: Array<felt252> = array![];
    calls.serialize(ref public_input);
    sigs.serialize(ref public_input);

    // v5 app_state = [nonce=0, threshold=2, n=3, members..., seed] (trailing salt_kit blinding).
    let seed = 0x5EED;
    let mut app_state: Array<felt252> = array![0, 2, 3];
    for m in members.span() {
        app_state.append(*m);
    };
    app_state.append(seed);
    let expected_old = commit(logic_class_hash, app_state.span());
    // Successor: nonce -> 1, committee + seed unchanged, same logic (immutable).
    let mut next_app_state: Array<felt252> = array![1, 2, 3];
    for m in members.span() {
        next_app_state.append(*m);
    };
    next_app_state.append(seed);
    let expected_new = commit(logic_class_hash, next_app_state.span());

    // Expected payload: [old, new, outputs.len=0, ...Serde(actions)].
    let mut expected_payload: Array<felt252> = array![expected_old, expected_new, 0];
    calls.serialize(ref expected_payload);

    let state = ShardState { logic_class_hash, app_state };
    let mut spy = spy_messages_to_l1();
    shard.transition(public_input, state);

    spy
        .assert_sent(
            @array![
                (
                    shard.contract_address,
                    MessageToL1 {
                        to_address: 0_felt252.try_into().unwrap(), payload: expected_payload,
                    },
                ),
            ],
        );
}

// ---------------------------------------------------------------------------
// consume (outbox execution) + outbox_of (settlement observability)
// ---------------------------------------------------------------------------

#[test]
fn consume_executes_recorded_transfer() {
    let shard = deploy_shard();
    let mock = deploy_mock_erc20(1000_u256);
    let recipient: felt252 = 0xBEEF;
    let amount: felt252 = 250;
    let entry_key = 0x1234; // stand-in for a transition's new_root

    let actions = array![
        PublicCall {
            to: mock.contract_address,
            selector: selector!("transfer"),
            calldata: array![recipient, amount, 0],
        },
    ];
    let ah = hash_actions(@actions);
    seed_outbox(shard, entry_key, ah);

    // outbox_of observes the pending entry, then its settlement (v4).
    assert(shard.outbox_of(entry_key) == ah, 'outbox_of pending');

    shard.consume(entry_key, actions);

    // The bundle's transfer actually ran against the (mock) token, and settled.
    assert(mock.last_recipient().into() == recipient, 'transfer recipient');
    assert(mock.last_amount() == amount.into(), 'transfer amount');
    assert(shard.outbox_of(entry_key) == 0, 'outbox_of settled');
}

#[test]
#[should_panic(expected: 'nothing to consume')]
fn consume_rejects_double_consume() {
    let shard = deploy_shard();
    let mock = deploy_mock_erc20(1000_u256);
    let entry_key = 0x1;
    let mk = || array![
        PublicCall {
            to: mock.contract_address, selector: selector!("transfer"),
            calldata: array![0xBEEF, 10, 0],
        },
    ];
    seed_outbox(shard, entry_key, hash_actions(@mk()));

    shard.consume(entry_key, mk()); // first: OK, clears the entry
    shard.consume(entry_key, mk()); // second: entry gone -> 'nothing to consume'
}

#[test]
#[should_panic(expected: 'actions mismatch')]
fn consume_rejects_hash_mismatch() {
    let shard = deploy_shard();
    let mock = deploy_mock_erc20(1000_u256);
    let entry_key = 0x2;
    let recorded = array![
        PublicCall {
            to: mock.contract_address, selector: selector!("transfer"),
            calldata: array![0xBEEF, 10, 0],
        },
    ];
    seed_outbox(shard, entry_key, hash_actions(@recorded));

    // Supply DIFFERENT actions (amount 999) — the recomputed hash won't match.
    let tampered = array![
        PublicCall {
            to: mock.contract_address, selector: selector!("transfer"),
            calldata: array![0xBEEF, 999, 0],
        },
    ];
    shard.consume(entry_key, tampered);
}

#[test]
#[should_panic(expected: 'self-call')]
fn consume_rejects_self_call() {
    let shard = deploy_shard();
    let entry_key = 0x3;
    // An action targeting the shard itself must be rejected.
    let actions = array![
        PublicCall {
            to: shard.contract_address, selector: selector!("get_root"), calldata: array![],
        },
    ];
    seed_outbox(shard, entry_key, hash_actions(@actions));
    shard.consume(entry_key, actions);
}

// ---------------------------------------------------------------------------
// v4 inbox (deposit / register_intent / views / fee / cap)
// ---------------------------------------------------------------------------

#[test]
fn register_intent_appends_and_reads_back() {
    let shard = deploy_shard();
    let caller: ContractAddress = 0xCA11E4_felt252.try_into().unwrap();

    assert(shard.inbox_len() == 0, 'inbox starts empty');

    start_cheat_caller_address(shard.contract_address, caller);
    shard.register_intent(array![0xE1, 0xE2, 0xE3]);
    stop_cheat_caller_address(shard.contract_address);

    assert(shard.inbox_len() == 1, 'one entry');
    let e = shard.inbox_entry(0);
    assert(e.kind == INBOX_KIND_INTENT, 'kind INTENT');
    assert(e.caller == caller, 'caller recorded');
    assert(e.data.len() == 3, 'payload len');
    assert(*e.data.at(0) == 0xE1, 'payload[0]');
    assert(*e.data.at(2) == 0xE3, 'payload[2]');
}

#[test]
#[should_panic(expected: 'payload too long')]
fn register_intent_rejects_oversized_payload() {
    let shard = deploy_shard();
    let mut payload: Array<felt252> = array![];
    let mut i: u32 = 0;
    while i != 65 { // cap is 64
        payload.append(i.into());
        i += 1;
    };
    shard.register_intent(payload);
}

#[test]
fn deposit_transfers_from_caller_and_records_entry() {
    let shard = deploy_shard();
    let mock = deploy_mock_erc20(0_u256);
    let depositor: ContractAddress = 0xD3B0517_felt252.try_into().unwrap();
    let amount: u256 = 500_u256;
    let note: felt252 = 0x5EC4E7;

    start_cheat_caller_address(shard.contract_address, depositor);
    shard.deposit(mock.contract_address, amount, note);
    stop_cheat_caller_address(shard.contract_address);

    // The FRAMEWORK executed the transfer_from(depositor -> shard): trustless attribution.
    assert(mock.last_from() == depositor, 'transfer_from sender');
    assert(mock.last_recipient() == shard.contract_address, 'transfer_from recipient');
    assert(mock.last_amount() == amount, 'transfer_from amount');

    let e = shard.inbox_entry(0);
    assert(e.kind == INBOX_KIND_DEPOSIT, 'kind DEPOSIT');
    assert(e.caller == depositor, 'depositor recorded');
    assert(*e.data.at(0) == mock.contract_address.into(), 'data token');
    assert(*e.data.at(1) == amount.low.into(), 'data amount.low');
    assert(*e.data.at(2) == amount.high.into(), 'data amount.high');
    assert(*e.data.at(3) == note, 'data note');
}

#[test]
#[should_panic(expected: 'zero deposit')]
fn deposit_rejects_zero_amount() {
    let shard = deploy_shard();
    let mock = deploy_mock_erc20(0_u256);
    shard.deposit(mock.contract_address, 0_u256, 0);
}

#[test]
fn deposit_records_actual_received_delta_not_nominal() {
    // Audit fix (finding 2): a fee-on-transfer token delivers less than the nominal
    // amount; the inbox must record the MEASURED delta, not the caller's request.
    let shard = deploy_shard();
    let mock = deploy_mock_erc20(0_u256);
    mock.set_transfer_fee(30_u256); // 30-unit fee: depositing 500 credits only 470
    let depositor: ContractAddress = 0xD3B0517_felt252.try_into().unwrap();

    start_cheat_caller_address(shard.contract_address, depositor);
    shard.deposit(mock.contract_address, 500_u256, 0x5EC4E7);
    stop_cheat_caller_address(shard.contract_address);

    let e = shard.inbox_entry(0);
    // Recorded amount is the real delta (470), NOT the nominal 500.
    assert(*e.data.at(1) == 470, 'records received delta');
    assert(*e.data.at(2) == 0, 'delta high 0');
}

#[test]
fn register_intent_charges_configured_fee() {
    let mock = deploy_mock_erc20(0_u256);
    let fee: u256 = 10_u256;
    let shard = deploy_shard_with(0, mock.contract_address, fee);
    let caller: ContractAddress = 0xF33_felt252.try_into().unwrap();

    start_cheat_caller_address(shard.contract_address, caller);
    shard.register_intent(array![0x1]);
    stop_cheat_caller_address(shard.contract_address);

    // The fee was pulled from the caller to the shard itself (anti-spam, not revenue).
    assert(mock.last_from() == caller, 'fee payer');
    assert(mock.last_recipient() == shard.contract_address, 'fee recipient');
    assert(mock.last_amount() == fee, 'fee amount');
    assert(shard.inbox_len() == 1, 'entry recorded');
}

#[test]
fn inbox_orders_mixed_entries_globally() {
    let shard = deploy_shard();
    let mock = deploy_mock_erc20(0_u256);

    shard.register_intent(array![0xA]);
    shard.deposit(mock.contract_address, 7_u256, 0xB);
    shard.register_intent(array![0xC]);

    assert(shard.inbox_len() == 3, 'three entries');
    assert(shard.inbox_entry(0).kind == INBOX_KIND_INTENT, 'seq 0 intent');
    assert(shard.inbox_entry(1).kind == INBOX_KIND_DEPOSIT, 'seq 1 deposit');
    assert(shard.inbox_entry(2).kind == INBOX_KIND_INTENT, 'seq 2 intent');
    assert(*shard.inbox_entry(2).data.at(0) == 0xC, 'seq 2 payload');
}

#[test]
#[should_panic(expected: 'inbox out of range')]
fn inbox_entry_rejects_out_of_range() {
    let shard = deploy_shard();
    shard.inbox_entry(0);
}
