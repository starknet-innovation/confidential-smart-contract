//! `ConfidentialShard` — the canonical, frozen confidential-shard framework contract.
//!
//! It is a THIN embedder of `ShardComponent` (src/shard_component.cairo) and adds NOTHING:
//! no `replace_class`, no owner/admin, no `root` setter. That emptiness is the point — the
//! contract is address-pinned and immutable, so a shard's committed logic-immutability is
//! real (the verifier can never be swapped or the root re-anchored). All mechanics live in
//! the audited component; this file just wires it in and forwards the constructor.
//!
//! A deployer wanting a different posture (e.g. an upgradeable variant) embeds the SAME
//! `ShardComponent` and adds their own wrapper — so upgradeability is opt-in to a variant,
//! never a property of this blessed contract. See DESIGN.md.

#[starknet::contract]
pub mod ConfidentialShard {
    use starknet::ContractAddress;
    use crate::shard_component::ShardComponent;

    component!(path: ShardComponent, storage: shard, event: ShardEvent);

    // The component's IShard implementation IS this contract's external ABI.
    #[abi(embed_v0)]
    impl ShardImpl = ShardComponent::ShardImpl<ContractState>;
    impl ShardInternalImpl = ShardComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        shard: ShardComponent::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        ShardEvent: ShardComponent::Event,
    }

    /// Genesis. `genesis_root` = commit(logic_class_hash0, app_state0), computed OFF-CHAIN
    /// (v5: no framework salt). `freshness_window` / intent fee are immutable per-shard
    /// params (0/0 = off).
    #[constructor]
    fn constructor(
        ref self: ContractState,
        genesis_root: felt252,
        freshness_window: u64,
        intent_fee_token: ContractAddress,
        intent_fee_amount: u256,
    ) {
        self.shard.initializer(genesis_root, freshness_window, intent_fee_token, intent_fee_amount);
    }
}
