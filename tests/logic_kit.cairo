//! Tests for the logic authoring kit (src/logic_kit.cairo). The call builders are pure;
//! `unseen_inbox` is exercised against a real deployed ConfidentialShard so the
//! proven-read cursor pattern is verified end-to-end.

use snforge_std::{
    declare, ContractClassTrait, DeclareResultTrait,
    start_cheat_caller_address, stop_cheat_caller_address,
};
use confidential_counter::logic_kit::{build_call, erc20_transfer_call, unseen_inbox, TRANSFER_SELECTOR};
use confidential_counter::interfaces::{IShardDispatcher, IShardDispatcherTrait, INBOX_KIND_INTENT};
use starknet::ContractAddress;

fn deploy_shard() -> IShardDispatcher {
    let fw = declare("ConfidentialShard").unwrap().contract_class();
    // (genesis_root, freshness_window, intent_fee_token, intent_fee amount low/high) — gates off.
    let (addr, _) = fw.deploy(@array![0x1, 0, 0, 0, 0]).unwrap();
    IShardDispatcher { contract_address: addr }
}

#[test]
fn build_call_passes_through() {
    let to: ContractAddress = 0xABC_felt252.try_into().unwrap();
    let c = build_call(to, 0x777, array![1, 2, 3]);
    assert(c.to == to, 'to');
    assert(c.selector == 0x777, 'selector');
    assert(c.calldata.len() == 3, 'calldata len');
    assert(*c.calldata.at(2) == 3, 'calldata[2]');
}

#[test]
fn erc20_transfer_call_encodes_transfer() {
    let token: ContractAddress = 0x7075_felt252.try_into().unwrap();
    let recipient: ContractAddress = 0xBEEF_felt252.try_into().unwrap();
    let amount: u256 = u256 { low: 500, high: 0 };

    let c = erc20_transfer_call(token, recipient, amount);
    assert(c.to == token, 'to == token');
    assert(c.selector == TRANSFER_SELECTOR, 'selector == transfer');
    assert(c.selector == selector!("transfer"), 'selector is sn_keccak');
    // calldata = [recipient, amount.low, amount.high]
    assert(c.calldata.len() == 3, 'calldata len');
    assert(*c.calldata.at(0) == recipient.into(), 'recipient');
    assert(*c.calldata.at(1) == 500, 'amount.low');
    assert(*c.calldata.at(2) == 0, 'amount.high');
}

#[test]
fn unseen_inbox_reads_from_cursor() {
    let shard = deploy_shard();
    let caller: ContractAddress = 0xCA11E4_felt252.try_into().unwrap();

    // Populate two inbox entries (register_intent is the simplest appender).
    start_cheat_caller_address(shard.contract_address, caller);
    shard.register_intent(array![0xA1]);
    shard.register_intent(array![0xB2, 0xB3]);
    stop_cheat_caller_address(shard.contract_address);

    // From cursor 0: both entries.
    let all = unseen_inbox(shard.contract_address, 0);
    assert(all.len() == 2, 'two unseen from 0');
    assert(*all.at(0).kind == INBOX_KIND_INTENT, 'entry 0 INTENT');
    assert(*all.at(1).data.at(1) == 0xB3, 'entry 1 payload');

    // From cursor 1: only the tail entry (confidential cursor advanced).
    let tail = unseen_inbox(shard.contract_address, 1);
    assert(tail.len() == 1, 'one unseen from 1');
    assert(*tail.at(0).data.at(0) == 0xB2, 'tail payload');

    // Fully caught up: nothing new.
    let none = unseen_inbox(shard.contract_address, 2);
    assert(none.len() == 0, 'none unseen from 2');
}
