//! Confidential peer-to-peer lending logic — the flagship inbox+outbox example, now with
//! a loan-specific **escape hatch** so no party depends on the operator's liveness.
//!
//! Alice lends USDC; Bob borrows against strkBTC collateral; Charlie operates. The market's
//! edge: **Alice's LTV parameters live in the commitment (hidden)**, so no one watching the
//! chain can compute the price at which Bob gets liquidated. Amounts are public (ordinary
//! ERC-20 deposits & transfers); only the LTV thresholds (and the salt) are private.
//!
//! ESCAPE HATCH (v2): the framework's `apply_transition` / `consume` are already
//! permissionless (security is the proof↔message binding + CAS, not caller identity), so
//! ANY party who can (a) produce a valid close proof and (b) prove a party authorized it can
//! settle the loan without Charlie. This logic supplies both:
//!   • AUTHORIZATION — every transition carries a SNIP-12 signature verified in-proof via the
//!     signer account's SRC-6 `is_valid_signature` (AA-native, like committee_logic). `take`
//!     must be signed by the BORROWER (binds Bob's consent to the hidden terms); `close` by
//!     ANY of {operator, lender, borrower}. So Alice or Bob can drive a settlement alone.
//!   • STATE AVAILABILITY (v3, salt_kit) — the shard carries a high-entropy `seed` in
//!     `app_state` (the blinding; hiding vs the public), established at origination and shared
//!     with the parties. Since v5 the framework has NO salt, so the commitment is
//!     `poseidon(logic, app_state)` and `step` (proven) is the sole author — the operator has
//!     no free secret blinding. Any party who knows the terms (they agreed them) + the seed
//!     can reconstruct EVERY state and self-prove, even against a MALICIOUS operator who
//!     cannot deviate the committed state. No cipher, no on-chain crypto (that's `da_kit`, for
//!     the harder blind-party case — see the sealed-register example).
//!   • EXPIRY — `close`'s past-due branch lets the LENDER liquidate if the loan isn't repaid
//!     by `start + duration`.
//! The proven guards (origination band; repay/liquidate/expiry at close) still constrain the
//! OUTCOME, so a signature only says WHO acts, never bends the result. `nonce` (in app_state)
//! makes each authorization single-use AND every `new_root` unique.
//!
//! LTV semantics: maxLTV = liquidation threshold; minLTV = Alice's yield floor (Bob must draw
//! enough). Draw is variable, bounded both sides. Prices: `oracle.get_price()` = loan-token
//! units per 1 collateral unit, scaled by `PRICE_SCALE`. Loan shards SHOULD set a non-zero
//! `freshness_window` (stale-price liquidation defense).
//!
//! app_state (21 felts; u256 fields are low/high pairs):
//!  [0] status(0=OFFERED,1=ACTIVE,2=CLOSED)  [1] lender  [2] borrower
//!  [3] collateral_token  [4] loan_token  [5] oracle
//!  [6,7] principal  [8] min_ltv_bps  [9] max_ltv_bps  [10] rate_bps  [11] duration(s)
//!  [12,13] debt  [14,15] collateral  [16] start_time  [17] inbox_seen
//!  [18] operator  [19] nonce  [20] seed (salt_kit blinding; carried unchanged)
//! public_input: Serde(draw: u256) ++ Serde(auth: MemberSig).
//! (take uses draw; close signs over draw=0. outputs is empty — parties reconstruct via seed.)

#[starknet::interface]
pub trait IPriceOracle<TState> {
    /// loan-token units per 1 collateral-token unit, scaled by `LendingLogic::PRICE_SCALE`.
    fn get_price(self: @TState) -> u256;
}

#[starknet::contract]
pub mod LendingLogic {
    use core::hash::{HashStateTrait, HashStateExTrait};
    use core::poseidon::PoseidonTrait;
    use core::poseidon::poseidon_hash_span;
    use starknet::{ContractAddress, get_contract_address, get_block_timestamp, get_tx_info};
    use openzeppelin_utils::cryptography::snip12::{StarknetDomain, StructHash};
    use crate::interfaces::{
        ILogic, PublicCall, InboxEntry, INBOX_KIND_DEPOSIT, IERC20Dispatcher, IERC20DispatcherTrait,
    };
    use crate::logic_kit::{erc20_transfer_call, unseen_inbox};
    use crate::logics::committee_logic::{ISRC6Dispatcher, ISRC6DispatcherTrait, MemberSig};
    use super::{IPriceOracleDispatcher, IPriceOracleDispatcherTrait};

    const OFFERED: felt252 = 0;
    const ACTIVE: felt252 = 1;
    const CLOSED: felt252 = 2;
    const BPS: u256 = 10000;
    const PRICE_SCALE: u256 = 1_000_000_000_000_000_000; // 1e18

    const OP_TAKE: felt252 = 'TAKE';
    const OP_CLOSE: felt252 = 'CLOSE';
    const OP_CANCEL: felt252 = 'CANCEL';
    const VALID: felt252 = 'VALID';
    /// SNIP-12 domain — MUST match the SDK's loanActionTypedData.
    const DOMAIN_NAME: felt252 = 'ConfShardLending';
    const DOMAIN_VERSION: felt252 = 1;
    /// SNIP-12 type hash of `"LoanAction"("shard":"ContractAddress","nonce":"felt","action_digest":"felt")`
    /// (pinned from starknet.js `typedData.getTypeHash`; a cross-check test asserts it).
    const LOAN_ACTION_TYPE_HASH: felt252 =
        0x9eceea84eec9f0761006fac5305b34611659b313105c4a5b316c5a2e3cafb7;

    #[storage]
    struct Storage {}

    /// The SNIP-12 message a party signs to authorize a transition: the shard, the current
    /// nonce (single-use), and a digest of the operation + amount.
    #[derive(Drop, Copy)]
    pub struct LoanAction {
        pub shard: felt252,
        pub nonce: felt252,
        pub action_digest: felt252,
    }

    impl LoanActionStructHash of StructHash<LoanAction> {
        fn hash_struct(self: @LoanAction) -> felt252 {
            PoseidonTrait::new()
                .update_with(LOAN_ACTION_TYPE_HASH)
                .update_with(*self.shard)
                .update_with(*self.nonce)
                .update_with(*self.action_digest)
                .finalize()
        }
    }

    #[abi(embed_v0)]
    impl LendingLogicImpl of ILogic<ContractState> {
        fn step(
            self: @ContractState,
            logic_class_hash: felt252,
            app_state: Array<felt252>,
            public_input: Array<felt252>,
        ) -> (felt252, Array<felt252>, Array<felt252>, Array<PublicCall>) {
            // public_input = Serde(draw: u256) ++ Serde(auth: MemberSig)
            let mut span = public_input.span();
            let draw: u256 = Serde::deserialize(ref span).expect('bad draw');
            let auth: MemberSig = Serde::deserialize(ref span).expect('bad auth');
            assert(span.len() == 0, 'trailing input');

            let status = *app_state.at(0);
            if status == OFFERED {
                // Role dispatch: the lender cancels their own offer (refund escrow); anyone
                // else takes. (A lender taking their own loan is nonsensical, so this is safe.)
                if auth.signer.into() == *app_state.at(1) {
                    cancel(logic_class_hash, @app_state, auth)
                } else {
                    take(logic_class_hash, @app_state, draw, auth)
                }
            } else {
                assert(status == ACTIVE, 'loan not open');
                close(logic_class_hash, @app_state, auth)
            }
        }
    }

    // ── take: Bob's collateral is in the inbox; Bob authorizes; enforce the hidden band ──
    fn take(
        logic_class_hash: felt252, s: @Array<felt252>, draw: u256, auth: MemberSig,
    ) -> (felt252, Array<felt252>, Array<felt252>, Array<PublicCall>) {
        let collateral_token: ContractAddress = (*s.at(3)).try_into().unwrap();
        let loan_token: ContractAddress = (*s.at(4)).try_into().unwrap();
        let oracle: ContractAddress = (*s.at(5)).try_into().unwrap();
        let principal = as_u256(*s.at(6), *s.at(7));
        let min_ltv: u256 = (*s.at(8)).into();
        let max_ltv: u256 = (*s.at(9)).into();
        let inbox_seen: u64 = (*s.at(17)).try_into().unwrap();
        let nonce = *s.at(19);

        let shard = get_contract_address();

        // AUTH first: the take signer IS the borrower. Bound to shard + nonce + (OP_TAKE, draw).
        let signer = verify_auth(shard, nonce, OP_TAKE, draw, auth);
        let borrower: ContractAddress = signer.try_into().unwrap();

        // Collateral = the borrower's OWN collateral_token deposits (scoped by depositor, so a
        // dust deposit from any other address can't hijack the borrower slot — audit fix).
        let entries = unseen_inbox(shard, inbox_seen);
        let collateral = sum_deposits(@entries, collateral_token, borrower);
        assert(collateral != 0, 'no collateral');

        // Enforce the HIDDEN band via cross-multiplication (no division):
        //   minLTV ≤ draw/V  ⇔  minLTV·(collateral·price) ≤ draw·SCALE·BPS.
        let price = IPriceOracleDispatcher { contract_address: oracle }.get_price();
        assert(price != 0, 'zero price'); // else the band collapses (audit fix)
        let vprime = collateral * price;
        let draw_scaled = draw * PRICE_SCALE * BPS;
        assert(min_ltv * vprime <= draw_scaled, 'below min ltv');
        assert(draw_scaled < max_ltv * vprime, 'above max ltv');

        assert(draw <= principal, 'exceeds principal');
        let bal = IERC20Dispatcher { contract_address: loan_token }.balance_of(shard);
        assert(bal >= draw, 'escrow missing');

        let n: u64 = entries.len().into();
        let new_seen: felt252 = (inbox_seen + n).into();
        let now: felt252 = get_block_timestamp().into();

        let new_state = array![
            ACTIVE, *s.at(1), borrower.into(), *s.at(3), *s.at(4), *s.at(5),
            *s.at(6), *s.at(7), *s.at(8), *s.at(9), *s.at(10), *s.at(11),
            draw.low.into(), draw.high.into(), collateral.low.into(), collateral.high.into(),
            now, new_seen, *s.at(18), nonce + 1, *s.at(20) // [20] = salt_kit seed (carried)
        ];
        let actions = array![erc20_transfer_call(loan_token, borrower, draw)];
        (logic_class_hash, new_state, array![], actions)
    }

    // ── close: the single settle method; any authorized party; branch forced by facts ──
    fn close(
        logic_class_hash: felt252, s: @Array<felt252>, auth: MemberSig,
    ) -> (felt252, Array<felt252>, Array<felt252>, Array<PublicCall>) {
        let lender: ContractAddress = (*s.at(1)).try_into().unwrap();
        let borrower: ContractAddress = (*s.at(2)).try_into().unwrap();
        let collateral_token: ContractAddress = (*s.at(3)).try_into().unwrap();
        let loan_token: ContractAddress = (*s.at(4)).try_into().unwrap();
        let oracle: ContractAddress = (*s.at(5)).try_into().unwrap();
        let principal = as_u256(*s.at(6), *s.at(7));
        let max_ltv: u256 = (*s.at(9)).into();
        let rate: u256 = (*s.at(10)).into();
        let duration: u64 = (*s.at(11)).try_into().unwrap();
        let debt = as_u256(*s.at(12), *s.at(13));
        let collateral = as_u256(*s.at(14), *s.at(15));
        let start: u64 = (*s.at(16)).try_into().unwrap();
        let inbox_seen: u64 = (*s.at(17)).try_into().unwrap();
        let operator = *s.at(18);
        let nonce = *s.at(19);

        // AUTH: any of {operator, lender, borrower} may trigger a settlement (the escape).
        let shard = get_contract_address();
        let signer = verify_auth(shard, nonce, OP_CLOSE, 0_u256, auth);
        assert(signer == operator || signer == lender.into() || signer == borrower.into(), 'not authorized');

        let owed = debt + debt * rate / BPS; // flat term interest
        let unlent = principal - debt;

        let entries = unseen_inbox(shard, inbox_seen);
        let repaid = sum_deposits(@entries, loan_token, borrower);

        let now = get_block_timestamp();
        let expired = now >= start + duration;

        let mut actions: Array<PublicCall> = array![];
        // Repayment WINS over expiry (audit fix): a fully-repaid borrower must never be
        // liquidated just because the close settled after `start + duration`. The repay path
        // also needs no oracle (only liquidation reads the price).
        if repaid >= owed {
            // REPAID: Alice made whole (unlent + owed); Bob gets collateral + any overpay.
            actions.append(erc20_transfer_call(loan_token, lender, unlent + owed));
            actions.append(erc20_transfer_call(collateral_token, borrower, collateral));
            let refund = repaid - owed;
            if refund != 0 {
                actions.append(erc20_transfer_call(loan_token, borrower, refund));
            }
        } else {
            // LIQUIDATE — only if the price crossed the hidden threshold, or past due.
            let price = IPriceOracleDispatcher { contract_address: oracle }.get_price();
            assert(price != 0, 'zero price'); // else the gate collapses to always-true (audit fix)
            let liquidatable = debt * PRICE_SCALE * BPS >= max_ltv * (collateral * price);
            assert(liquidatable || expired, 'loan healthy');
            actions.append(erc20_transfer_call(collateral_token, lender, collateral));
            let to_alice = unlent + repaid;
            if to_alice != 0 {
                actions.append(erc20_transfer_call(loan_token, lender, to_alice));
            }
        }

        let new_state = array![
            CLOSED, *s.at(1), *s.at(2), *s.at(3), *s.at(4), *s.at(5), *s.at(6), *s.at(7),
            *s.at(8), *s.at(9), *s.at(10), *s.at(11), *s.at(12), *s.at(13), *s.at(14),
            *s.at(15), *s.at(16), *s.at(17), *s.at(18), nonce + 1, *s.at(20) // [20] = seed
        ];
        (logic_class_hash, new_state, array![], actions)
    }

    /// Verify a SNIP-12 loan-action signature via the signer account's SRC-6
    /// `is_valid_signature` (a proven read). Returns the signer as a felt for membership
    /// checks. `action_digest = poseidon(op, amount.low, amount.high)`.
    fn verify_auth(shard: ContractAddress, nonce: felt252, op: felt252, amount: u256, auth: MemberSig) -> felt252 {
        let MemberSig { signer, signature } = auth;
        let action_digest = poseidon_hash_span(array![op, amount.low.into(), amount.high.into()].span());
        let hash = loan_action_message_hash(shard.into(), nonce, action_digest, signer);
        let ok = ISRC6Dispatcher { contract_address: signer }.is_valid_signature(hash, signature);
        assert(ok == VALID, 'bad signature');
        signer.into()
    }

    /// SNIP-12 message hash for `signer` (mirrors OZ's crate-private `OffchainMessageHash`):
    /// 'StarkNet Message' ‖ domain ‖ signer ‖ struct. Uses OZ's audited `StarknetDomain`.
    pub fn loan_action_message_hash(
        shard: felt252, nonce: felt252, action_digest: felt252, signer: ContractAddress,
    ) -> felt252 {
        let domain = StarknetDomain {
            name: DOMAIN_NAME, version: DOMAIN_VERSION, chain_id: get_tx_info().unbox().chain_id, revision: 1,
        };
        let message = LoanAction { shard, nonce, action_digest };
        PoseidonTrait::new()
            .update_with('StarkNet Message')
            .update_with(domain.hash_struct())
            .update_with(signer)
            .update_with(message.hash_struct())
            .finalize()
    }

    // ── cancel: the lender withdraws an unstaken OFFERED loan, reclaiming escrow (audit fix
    //    for the "no cancellation path strands escrow" finding). Only the lender may cancel. ──
    fn cancel(
        logic_class_hash: felt252, s: @Array<felt252>, auth: MemberSig,
    ) -> (felt252, Array<felt252>, Array<felt252>, Array<PublicCall>) {
        let lender: ContractAddress = (*s.at(1)).try_into().unwrap();
        let loan_token: ContractAddress = (*s.at(4)).try_into().unwrap();
        let nonce = *s.at(19);
        let shard = get_contract_address();

        let signer = verify_auth(shard, nonce, OP_CANCEL, 0_u256, auth);
        assert(signer == lender.into(), 'not lender');

        // Refund whatever loan_token escrow the shard holds back to the lender.
        let bal = IERC20Dispatcher { contract_address: loan_token }.balance_of(shard);
        let mut actions: Array<PublicCall> = array![];
        if bal != 0 {
            actions.append(erc20_transfer_call(loan_token, lender, bal));
        }
        let new_state = array![
            CLOSED, *s.at(1), *s.at(2), *s.at(3), *s.at(4), *s.at(5), *s.at(6), *s.at(7),
            *s.at(8), *s.at(9), *s.at(10), *s.at(11), *s.at(12), *s.at(13), *s.at(14),
            *s.at(15), *s.at(16), *s.at(17), *s.at(18), nonce + 1, *s.at(20),
        ];
        (logic_class_hash, new_state, array![], actions)
    }

    fn as_u256(low: felt252, high: felt252) -> u256 {
        u256 { low: low.try_into().unwrap(), high: high.try_into().unwrap() }
    }

    /// Sum of DEPOSIT amounts of `token` from `who`.
    fn sum_deposits(
        entries: @Array<InboxEntry>, token: ContractAddress, who: ContractAddress,
    ) -> u256 {
        let mut i: u32 = 0;
        let mut total: u256 = 0;
        while i != entries.len() {
            let e = entries.at(i);
            if *e.kind == INBOX_KIND_DEPOSIT && *e.caller == who {
                let t: ContractAddress = (*e.data.at(0)).try_into().unwrap();
                if t == token {
                    total += as_u256(*e.data.at(1), *e.data.at(2));
                }
            }
            i += 1;
        };
        total
    }
}
