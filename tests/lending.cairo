//! Confidential P2P lending tests (v3 — v5 framework + salt_kit escape hatch). Driven
//! THROUGH the framework: escrow USDC + post BTC collateral via inbox `deposit`, then call
//! `transition` and inspect the emitted message. Every transition carries a SNIP-12
//! signature (take=borrower; close=any of {operator, lender, borrower}) verified in-proof —
//! so the ESCAPE is exercised (Bob self-closes; Alice self-liquidates). v5: no framework
//! salt — blinding is a `seed` carried in app_state (index 20). `outputs` is empty (parties
//! reconstruct via the seed, not an echoed cipher).
//!
//! Scenario (18-dec tokens, price 1e18-scaled): 1 BTC = 50k USDC; Alice offers 40k at min
//! 50% / max 80% LTV, 10% flat, long duration. Bob draws 30k (60% LTV).

use snforge_std::{
    declare, ContractClassTrait, DeclareResultTrait, spy_messages_to_l1,
    MessageToL1SpyAssertionsTrait, MessageToL1, start_cheat_caller_address,
    stop_cheat_caller_address, start_cheat_block_timestamp_global, start_cheat_chain_id_global,
};
use snforge_std::signature::KeyPairTrait;
use snforge_std::signature::stark_curve::{StarkCurveKeyPairImpl, StarkCurveSignerImpl};
use confidential_counter::interfaces::{IShardDispatcher, IShardDispatcherTrait, ShardState, PublicCall};
use confidential_counter::logics::committee_logic::MemberSig;
use confidential_counter::logics::lending_logic::LendingLogic;
use confidential_counter::mocks::token_mock::{IMockTokenDispatcher, IMockTokenDispatcherTrait};
use confidential_counter::mocks::oracle_mock::IMockOracleDispatcher;
use core::poseidon::poseidon_hash_span;
use starknet::ContractAddress;

const CHAIN: felt252 = 'TESTCHAIN';
const OP_TAKE: felt252 = 'TAKE';
const OP_CLOSE: felt252 = 'CLOSE';
const OP_CANCEL: felt252 = 'CANCEL';
const SEED: felt252 = 0x5EED; // salt_kit blinding (arbitrary here; carried unchanged)

fn e18() -> u256 {
    1_000_000_000_000_000_000
}
fn commit(logic: felt252, app_state: Span<felt252>) -> felt252 {
    let mut data: Array<felt252> = array![logic, app_state.len().into()];
    for x in app_state {
        data.append(*x);
    };
    poseidon_hash_span(data.span())
}
fn logic_hash(name: ByteArray) -> felt252 {
    (*declare(name).unwrap().contract_class().class_hash).into()
}
fn deploy_shard() -> IShardDispatcher {
    let fw = declare("ConfidentialShard").unwrap().contract_class();
    let (addr, _) = fw.deploy(@array![0x1, 0, 0, 0, 0]).unwrap();
    IShardDispatcher { contract_address: addr }
}
fn deploy_token() -> IMockTokenDispatcher {
    let (addr, _) = declare("MockToken").unwrap().contract_class().deploy(@array![]).unwrap();
    IMockTokenDispatcher { contract_address: addr }
}
fn deploy_oracle(price: u256) -> IMockOracleDispatcher {
    let (addr, _) = declare("MockOracle").unwrap().contract_class()
        .deploy(@array![price.low.into(), price.high.into()]).unwrap();
    IMockOracleDispatcher { contract_address: addr }
}
fn deploy_account(public_key: felt252) -> ContractAddress {
    let (addr, _) = declare("MockAccount").unwrap().contract_class().deploy(@array![public_key]).unwrap();
    addr
}
fn fund_and_deposit(token: IMockTokenDispatcher, shard: IShardDispatcher, who: ContractAddress, amount: u256) {
    token.mint(who, amount);
    start_cheat_caller_address(token.contract_address, who);
    token.approve(shard.contract_address, amount);
    stop_cheat_caller_address(token.contract_address);
    start_cheat_caller_address(shard.contract_address, who);
    shard.deposit(token.contract_address, amount, 0);
    stop_cheat_caller_address(shard.contract_address);
}
fn loan_sig(
    kp: snforge_std::signature::KeyPair<felt252, felt252>,
    signer: ContractAddress, shard: ContractAddress, nonce: felt252, op: felt252, amount: u256,
) -> MemberSig {
    let digest = poseidon_hash_span(array![op, amount.low.into(), amount.high.into()].span());
    let hash = LendingLogic::loan_action_message_hash(shard.into(), nonce, digest, signer);
    let (r, s) = kp.sign(hash).unwrap();
    MemberSig { signer, signature: array![r, s] }
}
/// public_input = Serde(draw) ++ Serde(auth) — v3 (no cipher).
fn build_input(draw: u256, auth: MemberSig) -> Array<felt252> {
    let mut pi: Array<felt252> = array![];
    draw.serialize(ref pi);
    auth.serialize(ref pi);
    pi
}
/// The 21-felt lending app_state (v5: [20] = salt_kit seed).
fn loan_state(
    status: felt252, lender: ContractAddress, borrower: ContractAddress, coll: ContractAddress,
    loan: ContractAddress, oracle: ContractAddress, principal: u256, min_ltv: felt252,
    max_ltv: felt252, rate: felt252, duration: felt252, debt: u256, collateral: u256,
    start: felt252, inbox_seen: felt252, operator: ContractAddress, nonce: felt252, seed: felt252,
) -> Array<felt252> {
    array![
        status, lender.into(), borrower.into(), coll.into(), loan.into(), oracle.into(),
        principal.low.into(), principal.high.into(), min_ltv, max_ltv, rate, duration,
        debt.low.into(), debt.high.into(), collateral.low.into(), collateral.high.into(),
        start, inbox_seen, operator.into(), nonce, seed,
    ]
}
fn transfer_action(token: ContractAddress, to: ContractAddress, amount: u256) -> PublicCall {
    PublicCall { to: token, selector: selector!("transfer"), calldata: array![to.into(), amount.low.into(), amount.high.into()] }
}
fn eth_zero() -> starknet::EthAddress {
    0_felt252.try_into().unwrap()
}
/// Successor after close: status → CLOSED, nonce (index 19) → +1, rest (incl. seed) unchanged.
fn set_status_closed(s: @Array<felt252>) -> Array<felt252> {
    let mut out: Array<felt252> = array![2];
    let mut i: u32 = 1;
    while i != s.len() {
        if i == 19 {
            out.append(*s.at(19) + 1);
        } else {
            out.append(*s.at(i));
        }
        i += 1;
    };
    out
}

// ── SNIP-12 cross-check ──────────────────────────────────────────────────

#[test]
fn loan_action_hash_matches_offchain_snip12() {
    start_cheat_chain_id_global(CHAIN);
    let h = LendingLogic::loan_action_message_hash(0x123, 0x5, 0x99, 0x456.try_into().unwrap());
    assert(h == 0x650728057f5cfd2a633509ee5391595c5e6488878755a2dd325dc69adfe41f, 'snip12 hash mismatch');
}

// ── take (borrower-signed) ───────────────────────────────────────────────

#[test]
fn take_enforces_band_and_disburses() {
    start_cheat_chain_id_global(CHAIN);
    let logic = logic_hash("LendingLogic");
    let usdc = deploy_token();
    let btc = deploy_token();
    let oracle = deploy_oracle(50000 * e18());
    let shard = deploy_shard();
    let charlie = deploy_account(0xC);
    let kp_bob = KeyPairTrait::<felt252, felt252>::generate();
    let bob = deploy_account(kp_bob.public_key);
    let alice = deploy_account(0xA);

    let principal = 40000 * e18();
    let draw = 30000 * e18(); // 60% LTV
    let collateral = e18();
    fund_and_deposit(usdc, shard, alice, principal); // inbox[0] escrow
    fund_and_deposit(btc, shard, bob, collateral); //   inbox[1] collateral (Bob)
    start_cheat_block_timestamp_global(1000);

    let offered = loan_state(0, alice, 0.try_into().unwrap(), btc.contract_address, usdc.contract_address, oracle.contract_address, principal, 5000, 8000, 1000, 1000000, 0, 0, 0, 0, charlie, 0, SEED);
    let expected_old = commit(logic, offered.span());
    let active = loan_state(1, alice, bob, btc.contract_address, usdc.contract_address, oracle.contract_address, principal, 5000, 8000, 1000, 1000000, draw, collateral, 1000, 2, charlie, 1, SEED);
    let expected_new = commit(logic, active.span());

    let sig = loan_sig(kp_bob, bob, shard.contract_address, 0, OP_TAKE, draw);
    let mut expected_payload = array![expected_old, expected_new, 0]; // outputs empty
    array![transfer_action(usdc.contract_address, bob, draw)].serialize(ref expected_payload);

    let state = ShardState { logic_class_hash: logic, app_state: offered };
    let mut spy = spy_messages_to_l1();
    shard.transition(build_input(draw, sig), state);
    spy.assert_sent(@array![(shard.contract_address, MessageToL1 { to_address: eth_zero(), payload: expected_payload })]);
}

#[test]
#[should_panic(expected: 'no collateral')]
fn take_rejects_signer_without_collateral() {
    // v5+fix: collateral is scoped to the take signer; a signer who deposited none (here the
    // real collateral was deposited by Bob, but Mallory signs) is rejected 'no collateral'.
    start_cheat_chain_id_global(CHAIN);
    let logic = logic_hash("LendingLogic");
    let usdc = deploy_token();
    let btc = deploy_token();
    let oracle = deploy_oracle(50000 * e18());
    let shard = deploy_shard();
    let charlie = deploy_account(0xC);
    let kp_bob = KeyPairTrait::<felt252, felt252>::generate();
    let bob = deploy_account(kp_bob.public_key);
    let kp_mallory = KeyPairTrait::<felt252, felt252>::generate();
    let mallory = deploy_account(kp_mallory.public_key);
    let alice = deploy_account(0xA);
    let principal = 40000 * e18();
    fund_and_deposit(usdc, shard, alice, principal);
    fund_and_deposit(btc, shard, bob, e18());
    start_cheat_block_timestamp_global(1000);
    let offered = loan_state(0, alice, 0.try_into().unwrap(), btc.contract_address, usdc.contract_address, oracle.contract_address, principal, 5000, 8000, 1000, 1000000, 0, 0, 0, 0, charlie, 0, SEED);
    let sig = loan_sig(kp_mallory, mallory, shard.contract_address, 0, OP_TAKE, 30000 * e18());
    let state = ShardState { logic_class_hash: logic, app_state: offered };
    shard.transition(build_input(30000 * e18(), sig), state);
}

#[test]
#[should_panic(expected: 'below min ltv')]
fn take_rejects_draw_below_min_ltv() {
    start_cheat_chain_id_global(CHAIN);
    let logic = logic_hash("LendingLogic");
    let usdc = deploy_token();
    let btc = deploy_token();
    let oracle = deploy_oracle(50000 * e18());
    let shard = deploy_shard();
    let charlie = deploy_account(0xC);
    let kp_bob = KeyPairTrait::<felt252, felt252>::generate();
    let bob = deploy_account(kp_bob.public_key);
    let alice = deploy_account(0xA);
    let principal = 40000 * e18();
    fund_and_deposit(usdc, shard, alice, principal);
    fund_and_deposit(btc, shard, bob, e18());
    start_cheat_block_timestamp_global(1000);
    let offered = loan_state(0, alice, 0.try_into().unwrap(), btc.contract_address, usdc.contract_address, oracle.contract_address, principal, 5000, 8000, 1000, 1000000, 0, 0, 0, 0, charlie, 0, SEED);
    let draw = 20000 * e18(); // 40% < min 50%
    let sig = loan_sig(kp_bob, bob, shard.contract_address, 0, OP_TAKE, draw);
    let state = ShardState { logic_class_hash: logic, app_state: offered };
    shard.transition(build_input(draw, sig), state);
}

#[test]
#[should_panic(expected: 'above max ltv')]
fn take_rejects_draw_above_max_ltv() {
    start_cheat_chain_id_global(CHAIN);
    let logic = logic_hash("LendingLogic");
    let usdc = deploy_token();
    let btc = deploy_token();
    let oracle = deploy_oracle(50000 * e18());
    let shard = deploy_shard();
    let charlie = deploy_account(0xC);
    let kp_bob = KeyPairTrait::<felt252, felt252>::generate();
    let bob = deploy_account(kp_bob.public_key);
    let alice = deploy_account(0xA);
    let principal = 50000 * e18();
    fund_and_deposit(usdc, shard, alice, principal);
    fund_and_deposit(btc, shard, bob, e18());
    start_cheat_block_timestamp_global(1000);
    let offered = loan_state(0, alice, 0.try_into().unwrap(), btc.contract_address, usdc.contract_address, oracle.contract_address, principal, 5000, 8000, 1000, 1000000, 0, 0, 0, 0, charlie, 0, SEED);
    let draw = 42000 * e18(); // 84% >= max 80%
    let sig = loan_sig(kp_bob, bob, shard.contract_address, 0, OP_TAKE, draw);
    let state = ShardState { logic_class_hash: logic, app_state: offered };
    shard.transition(build_input(draw, sig), state);
}

// ── close (escape: any authorized party) ─────────────────────────────────

fn active_setup(
    price: u256, ts: u64,
) -> (
    felt252, IMockTokenDispatcher, IMockTokenDispatcher, IShardDispatcher, Array<felt252>,
    ContractAddress, ContractAddress, ContractAddress,
    snforge_std::signature::KeyPair<felt252, felt252>, snforge_std::signature::KeyPair<felt252, felt252>,
) {
    start_cheat_chain_id_global(CHAIN);
    let logic = logic_hash("LendingLogic");
    let usdc = deploy_token();
    let btc = deploy_token();
    let oracle = deploy_oracle(price);
    let shard = deploy_shard();
    let charlie = deploy_account(0xC);
    let kp_alice = KeyPairTrait::<felt252, felt252>::generate();
    let alice = deploy_account(kp_alice.public_key);
    let kp_bob = KeyPairTrait::<felt252, felt252>::generate();
    let bob = deploy_account(kp_bob.public_key);
    start_cheat_block_timestamp_global(ts);
    let active = loan_state(1, alice, bob, btc.contract_address, usdc.contract_address, oracle.contract_address, 40000 * e18(), 5000, 8000, 1000, 1000000, 30000 * e18(), e18(), 1000, 0, charlie, 0, SEED);
    (logic, usdc, btc, shard, active, charlie, alice, bob, kp_alice, kp_bob)
}

#[test]
fn borrower_self_closes_after_repay() {
    // ESCAPE: Bob repays and closes the loan HIMSELF (no operator). Healthy price, in term.
    let (logic, usdc, btc, shard, active, _charlie, alice, bob, _kpa, kp_bob) = active_setup(50000 * e18(), 2000);
    fund_and_deposit(usdc, shard, bob, 33000 * e18()); // inbox[0] repayment = owed
    let expected_old = commit(logic, active.span());
    let expected_new = commit(logic, set_status_closed(@active).span());
    // Alice: unlent (10k) + owed (33k) = 43k; Bob: collateral back.
    let mut expected_payload = array![expected_old, expected_new, 0]; // outputs empty
    array![
        transfer_action(usdc.contract_address, alice, 43000 * e18()),
        transfer_action(btc.contract_address, bob, e18()),
    ].serialize(ref expected_payload);
    let sig = loan_sig(kp_bob, bob, shard.contract_address, 0, OP_CLOSE, 0); // BORROWER signs
    let state = ShardState { logic_class_hash: logic, app_state: active };
    let mut spy = spy_messages_to_l1();
    shard.transition(build_input(0, sig), state);
    spy.assert_sent(@array![(shard.contract_address, MessageToL1 { to_address: eth_zero(), payload: expected_payload })]);
}

#[test]
fn lender_self_liquidates_on_expiry() {
    // ESCAPE: past due, not repaid — Alice liquidates HERSELF. Healthy price (60% LTV).
    let (logic, usdc, btc, shard, active, _charlie, alice, _bob, kp_alice, _kpb) = active_setup(50000 * e18(), 2_000_000);
    let expected_old = commit(logic, active.span());
    let expected_new = commit(logic, set_status_closed(@active).span());
    let mut expected_payload = array![expected_old, expected_new, 0];
    array![
        transfer_action(btc.contract_address, alice, e18()),
        transfer_action(usdc.contract_address, alice, 10000 * e18()), // unlent escrow
    ].serialize(ref expected_payload);
    let sig = loan_sig(kp_alice, alice, shard.contract_address, 0, OP_CLOSE, 0); // LENDER signs
    let state = ShardState { logic_class_hash: logic, app_state: active };
    let mut spy = spy_messages_to_l1();
    shard.transition(build_input(0, sig), state);
    spy.assert_sent(@array![(shard.contract_address, MessageToL1 { to_address: eth_zero(), payload: expected_payload })]);
}

#[test]
fn close_liquidates_when_price_crosses() {
    // Price crashes to 30k (LTV 100% >= max 80%); lender liquidates.
    let (logic, usdc, btc, shard, active, _charlie, alice, _bob, kp_alice, _kpb) = active_setup(30000 * e18(), 2000);
    let expected_old = commit(logic, active.span());
    let expected_new = commit(logic, set_status_closed(@active).span());
    let mut expected_payload = array![expected_old, expected_new, 0];
    array![
        transfer_action(btc.contract_address, alice, e18()),
        transfer_action(usdc.contract_address, alice, 10000 * e18()),
    ].serialize(ref expected_payload);
    let sig = loan_sig(kp_alice, alice, shard.contract_address, 0, OP_CLOSE, 0);
    let state = ShardState { logic_class_hash: logic, app_state: active };
    let mut spy = spy_messages_to_l1();
    shard.transition(build_input(0, sig), state);
    spy.assert_sent(@array![(shard.contract_address, MessageToL1 { to_address: eth_zero(), payload: expected_payload })]);
}

#[test]
#[should_panic(expected: 'not authorized')]
fn close_rejects_unauthorized_signer() {
    let (logic, _usdc, _btc, shard, active, _charlie, _alice, _bob, _kpa, _kpb) = active_setup(30000 * e18(), 2000);
    let kp_mallory = KeyPairTrait::<felt252, felt252>::generate();
    let mallory = deploy_account(kp_mallory.public_key);
    let sig = loan_sig(kp_mallory, mallory, shard.contract_address, 0, OP_CLOSE, 0);
    let state = ShardState { logic_class_hash: logic, app_state: active };
    shard.transition(build_input(0, sig), state);
}

#[test]
#[should_panic(expected: 'bad signature')]
fn close_rejects_bad_signature() {
    let (logic, _usdc, _btc, shard, active, _charlie, _alice, bob, _kpa, kp_bob) = active_setup(30000 * e18(), 2000);
    let sig = loan_sig(kp_bob, bob, shard.contract_address, 99, OP_CLOSE, 0); // nonce 99 != state 0
    let state = ShardState { logic_class_hash: logic, app_state: active };
    shard.transition(build_input(0, sig), state);
}

#[test]
#[should_panic(expected: 'loan healthy')]
fn close_rejects_healthy_loan() {
    let (logic, _usdc, _btc, shard, active, _charlie, _alice, bob, _kpa, kp_bob) = active_setup(50000 * e18(), 2000);
    let sig = loan_sig(kp_bob, bob, shard.contract_address, 0, OP_CLOSE, 0);
    let state = ShardState { logic_class_hash: logic, app_state: active };
    shard.transition(build_input(0, sig), state);
}

// ── audit-fix regressions ────────────────────────────────────────────────

#[test]
fn take_ignores_dust_frontrun_from_other_address() {
    // FIX #1: an attacker's dust collateral deposit (different address, FIRST in the inbox)
    // must not hijack the borrower slot — collateral is scoped to the take signer (Bob).
    start_cheat_chain_id_global(CHAIN);
    let logic = logic_hash("LendingLogic");
    let usdc = deploy_token();
    let btc = deploy_token();
    let oracle = deploy_oracle(50000 * e18());
    let shard = deploy_shard();
    let charlie = deploy_account(0xC);
    let kp_bob = KeyPairTrait::<felt252, felt252>::generate();
    let bob = deploy_account(kp_bob.public_key);
    let alice = deploy_account(0xA);
    let mallory = deploy_account(0x4A11);
    let principal = 40000 * e18();
    let draw = 30000 * e18();
    let collateral = e18();
    fund_and_deposit(usdc, shard, alice, principal); // inbox[0] escrow
    fund_and_deposit(btc, shard, mallory, 1); //         inbox[1] DUST front-run (attacker)
    fund_and_deposit(btc, shard, bob, collateral); //    inbox[2] Bob's real collateral
    start_cheat_block_timestamp_global(1000);

    let offered = loan_state(0, alice, 0.try_into().unwrap(), btc.contract_address, usdc.contract_address, oracle.contract_address, principal, 5000, 8000, 1000, 1000000, 0, 0, 0, 0, charlie, 0, SEED);
    let expected_old = commit(logic, offered.span());
    // Borrower = Bob (the signer); collateral = Bob's 1e18 (Mallory's dust excluded); seen=3.
    let active = loan_state(1, alice, bob, btc.contract_address, usdc.contract_address, oracle.contract_address, principal, 5000, 8000, 1000, 1000000, draw, collateral, 1000, 3, charlie, 1, SEED);
    let expected_new = commit(logic, active.span());
    let mut expected_payload = array![expected_old, expected_new, 0];
    array![transfer_action(usdc.contract_address, bob, draw)].serialize(ref expected_payload);

    let sig = loan_sig(kp_bob, bob, shard.contract_address, 0, OP_TAKE, draw);
    let state = ShardState { logic_class_hash: logic, app_state: offered };
    let mut spy = spy_messages_to_l1();
    shard.transition(build_input(draw, sig), state);
    spy.assert_sent(@array![(shard.contract_address, MessageToL1 { to_address: eth_zero(), payload: expected_payload })]);
}

#[test]
fn repaid_loan_closes_even_when_expired() {
    // FIX #2: a fully-repaid loan settled AFTER expiry must REPAY (collateral back to Bob),
    // not liquidate. ts is past start+duration; repaid == owed.
    let (logic, usdc, btc, shard, active, _charlie, alice, bob, _kpa, kp_bob) = active_setup(50000 * e18(), 2_000_000);
    fund_and_deposit(usdc, shard, bob, 33000 * e18()); // repaid = owed
    let expected_old = commit(logic, active.span());
    let expected_new = commit(logic, set_status_closed(@active).span());
    let mut expected_payload = array![expected_old, expected_new, 0];
    array![
        transfer_action(usdc.contract_address, alice, 43000 * e18()), // unlent 10k + owed 33k
        transfer_action(btc.contract_address, bob, e18()), //           collateral returned
    ].serialize(ref expected_payload);
    let sig = loan_sig(kp_bob, bob, shard.contract_address, 0, OP_CLOSE, 0);
    let state = ShardState { logic_class_hash: logic, app_state: active };
    let mut spy = spy_messages_to_l1();
    shard.transition(build_input(0, sig), state);
    spy.assert_sent(@array![(shard.contract_address, MessageToL1 { to_address: eth_zero(), payload: expected_payload })]);
}

#[test]
fn lender_cancels_offer_and_reclaims_escrow() {
    // FIX #4: the lender cancels an unstaken OFFERED loan and the escrow is refunded.
    start_cheat_chain_id_global(CHAIN);
    let logic = logic_hash("LendingLogic");
    let usdc = deploy_token();
    let btc = deploy_token();
    let oracle = deploy_oracle(50000 * e18());
    let shard = deploy_shard();
    let charlie = deploy_account(0xC);
    let kp_alice = KeyPairTrait::<felt252, felt252>::generate();
    let alice = deploy_account(kp_alice.public_key);
    let principal = 40000 * e18();
    fund_and_deposit(usdc, shard, alice, principal); // lender escrow sits in the shard
    start_cheat_block_timestamp_global(1000);

    let offered = loan_state(0, alice, 0.try_into().unwrap(), btc.contract_address, usdc.contract_address, oracle.contract_address, principal, 5000, 8000, 1000, 1000000, 0, 0, 0, 0, charlie, 0, SEED);
    let expected_old = commit(logic, offered.span());
    let expected_new = commit(logic, set_status_closed(@offered).span());
    let mut expected_payload = array![expected_old, expected_new, 0];
    array![transfer_action(usdc.contract_address, alice, principal)].serialize(ref expected_payload);

    // Lender signs OP_CANCEL; role dispatch routes signer==lender to cancel().
    let sig = loan_sig(kp_alice, alice, shard.contract_address, 0, OP_CANCEL, 0);
    let state = ShardState { logic_class_hash: logic, app_state: offered };
    let mut spy = spy_messages_to_l1();
    shard.transition(build_input(0, sig), state);
    spy.assert_sent(@array![(shard.contract_address, MessageToL1 { to_address: eth_zero(), payload: expected_payload })]);
}

#[test]
#[should_panic(expected: 'zero price')]
fn take_rejects_zero_price() {
    // FIX #5: a zero oracle price must not pass origination.
    start_cheat_chain_id_global(CHAIN);
    let logic = logic_hash("LendingLogic");
    let usdc = deploy_token();
    let btc = deploy_token();
    let oracle = deploy_oracle(0);
    let shard = deploy_shard();
    let charlie = deploy_account(0xC);
    let kp_bob = KeyPairTrait::<felt252, felt252>::generate();
    let bob = deploy_account(kp_bob.public_key);
    let alice = deploy_account(0xA);
    fund_and_deposit(usdc, shard, alice, 40000 * e18());
    fund_and_deposit(btc, shard, bob, e18());
    start_cheat_block_timestamp_global(1000);
    let offered = loan_state(0, alice, 0.try_into().unwrap(), btc.contract_address, usdc.contract_address, oracle.contract_address, 40000 * e18(), 5000, 8000, 1000, 1000000, 0, 0, 0, 0, charlie, 0, SEED);
    let sig = loan_sig(kp_bob, bob, shard.contract_address, 0, OP_TAKE, 30000 * e18());
    let state = ShardState { logic_class_hash: logic, app_state: offered };
    shard.transition(build_input(30000 * e18(), sig), state);
}

#[test]
#[should_panic(expected: 'zero price')]
fn close_rejects_zero_price_liquidation() {
    // FIX #5: a zero price must not collapse the liquidation gate to always-true. Not repaid,
    // not expired → the liquidate branch reads the price and rejects it.
    let (logic, _usdc, _btc, shard, active, _charlie, _alice, _bob, kp_alice, _kpb) = active_setup(0, 2000);
    let sig = loan_sig(kp_alice, _alice, shard.contract_address, 0, OP_CLOSE, 0);
    let state = ShardState { logic_class_hash: logic, app_state: active };
    shard.transition(build_input(0, sig), state);
}
