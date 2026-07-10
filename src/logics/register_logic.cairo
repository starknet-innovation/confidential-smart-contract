//! PrivateRegister — the reference example for `da_kit` (in-circuit encrypted DA).
//!
//! It stores a confidential `value` that a party may set. Unlike lending — where the parties
//! agreed the terms and can reconstruct state from the shared `seed` alone (salt_kit) — here a
//! party is BLIND to `value` (it's set arbitrarily by whoever transitions). So each transition
//! SEALS the successor state to every party's key via `da_kit::seal` and returns it as
//! `outputs`; the framework publishes it in the `Transitioned` event. A party recovers `value`
//! (and the whole state) by decrypting the latest blob with their stark account key, then
//! verifies it by `commit(state) == new_root`.
//!
//! Because the sealing is computed INSIDE `step`, the SNIP-36 proof guarantees the ciphertext
//! really is the committed state — a malicious operator cannot broadcast garbage. Combined
//! with v5 (no framework salt, so `step` is the sole author of every committed felt), this is
//! genuine MALICIOUS-operator-safe availability for blind parties. The `seed` still blinds the
//! commitment against the public (recovering one transition's blinding needs the seed).
//!
//! app_state = [nonce, value, seed, n_parties, key_1 .. key_n]
//!   (keys are the parties' stark public-key x-coordinates — the da_kit recipients)
//! public_input = [new_value, eph]  (eph = ephemeral ECIES scalar, fresh per transition)
//! outputs = da_kit::seal(new_app_state, party_keys, eph, new_nonce)

#[starknet::contract]
pub mod PrivateRegisterLogic {
    use crate::interfaces::{ILogic, PublicCall};
    use crate::da_kit;

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl PrivateRegisterImpl of ILogic<ContractState> {
        fn step(
            self: @ContractState,
            logic_class_hash: felt252,
            app_state: Array<felt252>,
            public_input: Array<felt252>,
        ) -> (felt252, Array<felt252>, Array<felt252>, Array<PublicCall>) {
            let nonce = *app_state.at(0);
            let seed = *app_state.at(2);
            let n: u32 = (*app_state.at(3)).try_into().unwrap();
            let new_value = *public_input.at(0);
            let eph = *public_input.at(1);
            let new_nonce = nonce + 1;

            // Successor: nonce++, new value, seed + party keys carried unchanged.
            let mut new_app_state: Array<felt252> = array![new_nonce, new_value, seed, n.into()];
            let mut party_keys: Array<felt252> = array![];
            let mut i: u32 = 0;
            while i != n {
                let key = *app_state.at(4 + i);
                new_app_state.append(key);
                party_keys.append(key);
                i += 1;
            };

            // Seal the successor state to every party — proven in-circuit, so the published
            // ciphertext IS the committed state (no garbage broadcast possible).
            let outputs = da_kit::seal(new_app_state.span(), party_keys.span(), eph, new_nonce);

            let no_actions: Array<PublicCall> = array![];
            (logic_class_hash, new_app_state, outputs, no_actions)
        }
    }
}
