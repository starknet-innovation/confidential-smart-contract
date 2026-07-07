//! Private claim logic — an IMMUTABLE confidential allowlist example.
//!
//! app_state = [total_claimed, n, account_0, allocation_0, claimed_0, ...] — EXACTLY
//!             HEADER_LEN + n * ROW_WIDTH felts (a malformed length reverts fail-closed).
//! public_input = [claimant].
//!
//! A successful claim proves that `claimant` appears in the private table, has not
//! claimed yet, and receives exactly its private allocation. The full allowlist,
//! non-claimants, and unclaimed allocations remain unpublished. NOTE the public output
//! is [claimant, allocation, total_claimed_after]: a claim reveals the claimant's
//! identity and exact allocation on-chain — confidentiality covers the untouched table,
//! not the individual claim.
//!
//! Only the FIRST matching row is claimed (an allowlist is expected to hold each account
//! at most once; duplicates leave later rows untouched). `total_claimed` is trusted as
//! committed, not re-derived from the rows — genesis consistency (total vs. pre-claimed
//! rows) is the deployer's responsibility.
//!
//! The off-chain mirror `orchestration/src/examples/private_claim.ts` MUST reproduce this
//! row-for-row so the caller can pre-check `new_root` before broadcasting. Keep ROW_WIDTH,
//! HEADER_LEN, the first-match rule, and the length check in sync across both files.

#[starknet::contract]
pub mod PrivateClaimLogic {
    use crate::interfaces::ILogic;

    const ROW_WIDTH: usize = 3;
    const HEADER_LEN: usize = 2;

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl PrivateClaimLogicImpl of ILogic<ContractState> {
        fn step(
            self: @ContractState,
            logic_class_hash: felt252,
            app_state: Array<felt252>,
            public_input: Array<felt252>,
        ) -> (felt252, Array<felt252>, Array<felt252>) {
            // Early length guards before any .at() to produce clear errors instead of
            // index-out-of-bounds panics. Mirrors the documented expectations.
            assert!(public_input.len() == 1, "bad_public_input_len");
            assert!(app_state.len() >= HEADER_LEN, "bad_state_len");

            let claimant = *public_input.at(0);
            let total_claimed: u128 = (*app_state.at(0)).try_into().expect('total not u128');
            let n: usize = (*app_state.at(1)).try_into().expect('n not usize');
            assert!(app_state.len() == HEADER_LEN + n * ROW_WIDTH, "bad_state_len");

            // Single pass: copy every row into the successor, flipping the claimed flag on
            // ONLY the first matching (still-unclaimed) row. Mirrors the off-chain nextState.
            let mut found = false;
            let mut allocation: u128 = 0;
            let mut rows: Array<felt252> = array![];

            for i in 0..n {
                let base = HEADER_LEN + i * ROW_WIDTH;
                let account = *app_state.at(base);
                let row_allocation = *app_state.at(base + 1);
                let claimed = *app_state.at(base + 2);

                let next_claimed = if !found && account == claimant {
                    assert!(claimed == 0, "already_claimed");
                    allocation = row_allocation.try_into().expect('alloc not u128');
                    found = true;
                    1
                } else {
                    claimed
                };

                rows.append(account);
                rows.append(row_allocation);
                rows.append(next_claimed);
            }

            assert!(found, "claimant_missing");

            // Checked u128 add: reverts on overflow (no felt252 wraparound).
            let new_total = total_claimed + allocation;
            let mut new_state: Array<felt252> = array![new_total.into(), n.into()];
            for x in rows.span() {
                new_state.append(*x);
            }

            (logic_class_hash, new_state, array![claimant, allocation.into(), new_total.into()])
        }
    }
}
