//! Authoring kit for confidential shard logics — pure, reusable helpers for the
//! repetitive parts of implementing `ILogic::step`.
//!
//! This module is NOT part of the frozen framework (it adds no contract, no storage, no
//! trust surface); it is optional convenience a logic author may import:
//!
//!     use crate::logic_kit::{build_call, erc20_transfer_call, unseen_inbox};
//!
//! See `src/logics/template_logic.cairo` for how they slot into a `step`, and
//! `src/logics/committee_logic.cairo` for a real outbox logic.

use starknet::ContractAddress;
use crate::interfaces::{PublicCall, InboxEntry, IShardDispatcher, IShardDispatcherTrait};

/// ERC-20 `transfer(recipient, amount: u256)` entry-point selector (sn_keccak).
pub const TRANSFER_SELECTOR: felt252 = selector!("transfer");

/// Build a `PublicCall` for the outbox. On `consume`, the shard executes it AS ITSELF
/// (`get_caller_address()` at `to` == the shard), so it exercises only authority the shard
/// already holds.
pub fn build_call(to: ContractAddress, selector: felt252, calldata: Array<felt252>) -> PublicCall {
    PublicCall { to, selector, calldata }
}

/// The most common outbox action: move `amount` of `token` from the shard to `recipient`.
/// The shard must already HOLD the tokens (e.g. received via `deposit`). Calldata is the
/// standard `transfer(recipient, amount)` = `[recipient, amount.low, amount.high]`.
pub fn erc20_transfer_call(token: ContractAddress, recipient: ContractAddress, amount: u256) -> PublicCall {
    let mut calldata: Array<felt252> = array![];
    Serde::serialize(@recipient, ref calldata);
    Serde::serialize(@amount, ref calldata);
    PublicCall { to: token, selector: TRANSFER_SELECTOR, calldata }
}

/// Read every inbox entry the logic has not yet seen: sequence numbers `(seen, inbox_len]`.
///
/// This is a PROVEN read against the SNIP-36 reference block — call it from `step` with
/// `starknet::get_contract_address()` as `shard` (the logic runs in the shard's context).
/// The framework never marks entries consumed; advance your OWN confidential cursor by
/// storing the returned length in `app_state`, so WHAT you have processed stays private.
pub fn unseen_inbox(shard: ContractAddress, seen: u64) -> Array<InboxEntry> {
    let dispatcher = IShardDispatcher { contract_address: shard };
    let len = dispatcher.inbox_len();
    let mut out: Array<InboxEntry> = array![];
    let mut seq = seen;
    while seq != len {
        out.append(dispatcher.inbox_entry(seq));
        seq += 1;
    };
    out
}
