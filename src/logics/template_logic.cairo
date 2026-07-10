//! TEMPLATE LOGIC — copy this file to start a new confidential app.
//!
//! It implements the frozen `ILogic::step` (src/interfaces.cairo) with the smallest real
//! body, plus inline guidance for the four things most logics do: read/return app_state,
//! read public_input, (optionally) emit outbox actions, and (optionally) consume the
//! inbox. To build your app: rename `TemplateLogic`, fill in `step`, declare the class,
//! and mirror your app_state / public_input layout in a TypeScript `Logic<State, Action>`
//! (orchestration/src/apps/*.ts).
//!
//! RULES the framework enforces (see interfaces.cairo):
//!  - `step` MUST NOT write storage and MUST NOT emit L2->L1 messages (the framework is
//!    the sole emitter; a logic that emits makes `proof_facts[7] != 1` and fails closed).
//!    It MAY read public state — those reads are proven against the reference block.
//!  - Return your OWN class hash to stay immutable (the safe default all references use);
//!    return a DIFFERENT one, gated by your own authorization, to upgrade the logic.
//!  - v5: the framework has NO salt — the commitment is `poseidon(logic, app_state)` and
//!    `step` is the SOLE author of every committed felt. HIDING is therefore YOUR choice:
//!      · public logic (like this template / CounterLogic): keep no blinding — transparent.
//!      · hidden state whose parties can reconstruct it (they know the terms): keep a
//!        high-entropy `seed` in app_state and carry it (see `salt_kit` / LendingLogic).
//!      · hidden state a party is BLIND to: seal it to the parties' keys via `da_kit::seal`
//!        into `outputs` so they can decrypt + resume (see register_logic.cairo).
//!
//! Toy behaviour: app_state = [value]; public_input = [new_value]; it stores new_value
//! (transparent — no blinding). Replace the body with your real transition.

#[starknet::contract]
pub mod TemplateLogic {
    use crate::interfaces::{ILogic, PublicCall};
    // Optional authoring helpers — uncomment what you use:
    // use crate::logic_kit::{erc20_transfer_call, unseen_inbox};
    // use starknet::get_contract_address;

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl TemplateLogicImpl of ILogic<ContractState> {
        fn step(
            self: @ContractState,
            logic_class_hash: felt252,
            app_state: Array<felt252>,
            public_input: Array<felt252>,
        ) -> (felt252, Array<felt252>, Array<felt252>, Array<PublicCall>) {
            // 1. DECODE state + input (must match your TS encodeState / buildPublicInput).
            let _value = *app_state.at(0);
            let new_value = *public_input.at(0);

            // 2. VALIDATE — assert authorization / invariants here. For an AA-native
            //    threshold check via `is_valid_signature`, see committee_logic.cairo.

            // 3. (OPTIONAL) EMIT OUTBOX ACTIONS — public calls the shard runs AS ITSELF on
            //    `consume`. Build them with the kit, e.g.:
            //        let actions = array![erc20_transfer_call(token, recipient, amount)];
            //    Return an empty array for a pure, effect-free logic (like this template).
            let actions: Array<PublicCall> = array![];

            // 4. (OPTIONAL) CONSUME THE INBOX — proven reads of deposits / intents since
            //    your last cursor. Keep the cursor in app_state so it stays confidential:
            //        let entries = unseen_inbox(get_contract_address(), seen);
            //        // ...process entries, advance `seen`, fold into new_app_state...

            // 5. RETURN (next_logic_class_hash, new_app_state, outputs, actions):
            //    - self-perpetuate (immutable): return `logic_class_hash`.
            //    - keep a blinding `seed` in new_app_state if you want hiding (salt_kit).
            //    - `outputs`: felts to publish (e.g. `da_kit::seal(new_app_state, keys, eph,
            //      nonce)` for encrypted DA); empty here (transparent).
            (logic_class_hash, array![new_value], array![], actions)
        }
    }
}
