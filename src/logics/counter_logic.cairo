//! Counter logic — a minimal, IMMUTABLE dummy example of a framework logic.
//!
//! app_state = [count]; public_input = [step]. `step` increments the counter and always
//! returns its OWN class hash, so a shard governed by this logic can never change logic:
//! its behaviour is fixed and only the count evolves (like a non-upgradeable contract).
//!
//! This is deliberately the SAFE default — no reference logic ships an upgrade path
//! (audit finding #2). The framework still *supports* upgrades: a production logic that
//! wants them returns a *different* successor class hash from `step`, gated by its own
//! authorization (signature / quorum / allow-list encoded in app_state). This dummy does
//! not, so it cannot be hijacked into a different logic by anyone holding the state.

#[starknet::contract]
pub mod CounterLogic {
    use crate::interfaces::ILogic;

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl CounterLogicImpl of ILogic<ContractState> {
        fn step(
            self: @ContractState,
            logic_class_hash: felt252,
            app_state: Array<felt252>,
            public_input: Array<felt252>,
        ) -> (felt252, Array<felt252>, Array<felt252>) {
            // Bounded arithmetic (audit finding #1): checked u128 add reverts on overflow
            // instead of wrapping felt252.
            let count: u128 = (*app_state.at(0)).try_into().expect('count not u128');
            let step_amt: u128 = (*public_input.at(0)).try_into().expect('step not u128');
            let new_count: u128 = count + step_amt;

            // IMMUTABLE: always self-perpetuate. The successor is always this same class
            // hash, regardless of any extra public_input — there is no upgrade path.
            (logic_class_hash, array![new_count.into()], array![step_amt.into()])
        }
    }
}
