//! Shared types + interfaces for the confidential shard framework.
//!
//! The framework is generic: it commits to an opaque `app_state` and delegates the
//! actual state transition to a pluggable logic class named by `logic_class_hash`.
//! Critically, `logic_class_hash` lives INSIDE the committed state, so which logic
//! governs a shard is itself confidential and enforced by the commitment.

use starknet::ContractAddress;

/// The full confidential off-chain state. Committed to `root`; published nowhere.
///
/// `logic_class_hash` names the pluggable logic that governs this shard. It lives
/// inside the commitment, so it is enforced cryptographically: the on-chain CAS
/// pins `old_root` to the live anchor, and `old_root` pins `logic_class_hash` (a
/// prover cannot substitute a different logic without breaking Poseidon preimage
/// resistance).
///
/// v5: there is NO framework salt. Blinding is a LOGIC-LEVEL policy, not a framework
/// mechanism — the commitment is `poseidon(logic_class_hash, app_state)` and the logic
/// is the SOLE author of every committed felt (via `step`). A logic that wants hiding
/// keeps a high-entropy blinding field in `app_state` (see `salt_kit`); a public logic
/// keeps none. This is deliberate: a framework-chosen `new_salt` was a SECRET the
/// OPERATOR alone knew (only `new_root` is published), so a malicious operator could
/// pick an unrecoverable salt and lock the parties out of ever reconstructing the state.
/// With blinding in `app_state`, the proven `step` controls it, so any party who knows
/// the logic's blinding (e.g. a shared seed) can always reconstruct and self-prove —
/// the escape hatch holds against a MALICIOUS operator, not just an absent one.
#[derive(Drop, Serde)]
pub struct ShardState {
    pub logic_class_hash: felt252,
    pub app_state: Array<felt252>,
}

/// A public Starknet call the shard should execute as a side effect of a transition.
/// The shard acts AS ITSELF (`get_caller_address()` at the target = the shard address),
/// so it can only exercise on-chain authority it already holds (its own balances /
/// approvals). Actions are carried inside the proven `PublicMessage`, so they are
/// commitment-bound (a prover cannot add/edit/forge them). They are NOT executed
/// during `apply_transition`; they are recorded to an outbox and pushed through later
/// by `consume` (pull, one-shot) — see framework.cairo.
#[derive(Drop, Serde)]
pub struct PublicCall {
    pub to: ContractAddress,
    pub selector: felt252,
    pub calldata: Array<felt252>,
}

/// The public claim carried in the virtual function's L2->L1 message and
/// re-supplied verbatim as `apply_transition` calldata. `outputs` is whatever the
/// logic chose to make public this transition (e.g. an encrypted-DA blob — see
/// DESIGN.md "Inbox (v4)"); `actions` is the (possibly empty) list of public calls
/// the logic wants executed. Both are covered by the proof<->message hash, so neither
/// can be tampered with between proving and applying.
#[derive(Drop, Serde)]
pub struct PublicMessage {
    pub old_root: felt252,
    pub new_root: felt252,
    pub outputs: Array<felt252>,
    pub actions: Array<PublicCall>,
}

/// One inbox record — the public → shard channel, the dual of the outbox (v4).
/// Appended on-chain by `deposit` / `register_intent`; read by logics through the
/// `inbox_entry` view during the virtual transition (a PROVEN read against the
/// SNIP-36 reference block). The framework never interprets `data` and never marks
/// entries consumed — consumption is a confidential cursor (`inbox_seen`) kept in the
/// logic's app_state, invisible on-chain.
#[derive(Drop, Serde)]
pub struct InboxEntry {
    /// `INBOX_KIND_DEPOSIT` or `INBOX_KIND_INTENT`.
    pub kind: felt252,
    pub caller: ContractAddress,
    pub block_number: u64,
    /// DEPOSIT: `[token, amount.low, amount.high, note]`. INTENT: the raw payload.
    pub data: Array<felt252>,
}

pub const INBOX_KIND_DEPOSIT: felt252 = 'DEPOSIT';
pub const INBOX_KIND_INTENT: felt252 = 'INTENT';

/// Minimal ERC-20 surface the framework itself needs (deposits + the intent fee).
/// The framework performing the `transfer_from` is what makes deposit attribution
/// trustless: the inbox entry is proof the funds arrived from `caller`. `balance_of`
/// lets `deposit` record the ACTUAL received delta (fee-on-transfer / rebasing safe)
/// rather than the caller's nominal request.
#[starknet::interface]
pub trait IERC20<TContractState> {
    fn balance_of(self: @TContractState, account: ContractAddress) -> u256;
    fn transfer_from(
        ref self: TContractState,
        sender: ContractAddress,
        recipient: ContractAddress,
        amount: u256,
    ) -> bool;
}

/// The generic, frozen framework interface. This contract is the trust root: it is
/// address-pinned and must never gain an upgrade / admin / root-setter path.
#[starknet::interface]
pub trait IShard<TContractState> {
    /// VIRTUAL — proven off-chain. Commits `old_root` = poseidon(logic_class_hash,
    /// app_state), `library_call`s the committed logic's `step`, commits `new_root` over
    /// the successor the logic returns, and emits `{old_root, new_root, outputs, actions}`.
    /// v5: no framework salt — blinding, if any, is a field the logic keeps in `app_state`.
    fn transition(
        ref self: TContractState, public_input: Array<felt252>, private_input: ShardState,
    );

    /// ON-CHAIN — submitted with `{proof, proofFacts}`. Verifies the proof<->message
    /// binding, compare-and-swaps the anchored root, and RECORDS any `actions` to the
    /// outbox (keyed by `new_root`). Does not execute them. Logic-agnostic.
    fn apply_transition(ref self: TContractState, msg: PublicMessage);

    /// ON-CHAIN, PERMISSIONLESS — executes a previously-recorded outbox bundle. Anyone
    /// can push it through (relayer-friendly, like L1's `consumeMessageFromL2`).
    /// `entry_key` is the `new_root` under which `apply_transition` recorded the bundle;
    /// `actions` must hash to the recorded commitment. One-shot (replay-protected).
    fn consume(ref self: TContractState, entry_key: felt252, actions: Array<PublicCall>);

    /// ON-CHAIN, PERMISSIONLESS (v4) — deposit ERC-20 into the shard, trustlessly
    /// attributed: the framework performs the `transfer_from(caller → shard)` itself and
    /// appends a DEPOSIT inbox entry `[token, amount.low, amount.high, note]`. `note`
    /// lets the depositor bind the funds to a confidential identity (e.g. a commitment
    /// to a shard-internal key). Requires prior ERC-20 `approve`.
    fn deposit(ref self: TContractState, token: ContractAddress, amount: u256, note: felt252);

    /// ON-CHAIN, PERMISSIONLESS (v4) — file an uninterpreted intent (e.g. an exit
    /// request) for the confidential logic to observe. Payload length is capped. If the
    /// shard was instantiated with a non-zero intent fee, it is transferred to the shard
    /// (anti-spam; requires prior `approve`).
    fn register_intent(ref self: TContractState, payload: Array<felt252>);

    /// Number of inbox entries (v4). With `inbox_entry`, this is the proven-read
    /// surface a logic consumes: read `inbox_len` at the reference block, process
    /// entries `(inbox_seen, inbox_len]`, advance the confidential cursor.
    fn inbox_len(self: @TContractState) -> u64;

    /// Read one inbox entry by sequence number (v4). Reverts if out of range.
    fn inbox_entry(self: @TContractState, seq: u64) -> InboxEntry;

    /// Outbox settlement observability (v4): the stored commitment for `entry_key`
    /// (a transition's `new_root`), or 0 if nothing was recorded / already consumed.
    /// Lets a logic PROVE whether a prior action bundle settled — the missing piece
    /// for honest reserved-balance accounting.
    fn outbox_of(self: @TContractState, entry_key: felt252) -> felt252;

    /// Current anchored commitment.
    fn get_root(self: @TContractState) -> felt252;
}

/// The pluggable logic interface. Any DECLARED class implementing this can govern a
/// shard (declaring is public — you hide which logic a shard uses, not the code).
///
/// `step` MUST NOT write storage and MUST NOT emit L2->L1 messages (the framework is
/// the sole emitter; a logic that emits makes `proof_facts[7] != 1` and the transition
/// fails closed). It MAY READ public state during the virtual execution — e.g. call an
/// oracle's view, or read the shard's own on-chain balance — because SNIP-36 proves the
/// execution against a reference block, so those reads are covered by the proof. (Note:
/// a logic can bound freshness of what it reads relative to the reference block, and
/// SNIP-36 bounds how old the reference block may be; it cannot bound the
/// reference->apply gap — that is an apply-time property.)
///
/// It returns `(next_logic_class_hash, new_app_state, outputs, actions)`. Return the
/// SAME `logic_class_hash` to self-perpetuate; return a DIFFERENT one to upgrade. A
/// logic that always returns its own hash is permanently immutable (a one-way ratchet).
/// `actions` is the list of public calls to record to the outbox this transition
/// (return an empty array for a pure, effect-free logic).
#[starknet::interface]
pub trait ILogic<TContractState> {
    fn step(
        self: @TContractState,
        logic_class_hash: felt252,
        app_state: Array<felt252>,
        public_input: Array<felt252>,
    ) -> (felt252, Array<felt252>, Array<felt252>, Array<PublicCall>);
}
