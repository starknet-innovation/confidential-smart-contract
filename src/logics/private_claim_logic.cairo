//! Private claim logic — an IMMUTABLE confidential allowlist example.
//!
//! app_state = [total_claimed, n, account_0, allocation_0, claimed_0, ...].
//! public_input = [claimant].
//!
//! A successful claim proves that `claimant` appears in the private table, has not
//! claimed yet, and receives exactly its private allocation. The full allowlist,
//! non-claimants, and unclaimed allocations remain unpublished.

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
            let claimant = *public_input.at(0);
            let total_claimed: u128 = (*app_state.at(0)).try_into().expect('total not u128');
            let n: usize = (*app_state.at(1)).try_into().expect('n not usize');

            let mut i = 0;
            let mut found = false;
            let mut allocation: u128 = 0;

            loop {
                if i == n {
                    break;
                }

                let base = HEADER_LEN + i * ROW_WIDTH;
                let account = *app_state.at(base);
                if account == claimant {
                    let claimed = *app_state.at(base + 2);
                    assert!(claimed == 0, "already_claimed");
                    allocation = (*app_state.at(base + 1)).try_into().expect('alloc not u128');
                    found = true;
                    break;
                }

                i += 1;
            };

            assert!(found, "claimant_missing");

            let new_total = total_claimed + allocation;
            let mut new_state: Array<felt252> = array![new_total.into(), n.into()];

            let mut j = 0;
            loop {
                if j == n {
                    break;
                }

                let base = HEADER_LEN + j * ROW_WIDTH;
                let account = *app_state.at(base);
                let row_allocation = *app_state.at(base + 1);
                let claimed = *app_state.at(base + 2);
                let next_claimed = if account == claimant { 1 } else { claimed };

                new_state.append(account);
                new_state.append(row_allocation);
                new_state.append(next_claimed);

                j += 1;
            };

            (logic_class_hash, new_state, array![claimant, allocation.into(), new_total.into()])
        }
    }
}
