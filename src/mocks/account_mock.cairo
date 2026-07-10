//! Test-only SNIP-6 mock account. NOT part of the trust surface — it exists so snforge
//! can exercise `CommitteeLogic`'s `is_valid_signature` path without a real account.
//! Lives under `mocks/` (pruned by the auditor). `is_valid_signature` verifies a
//! stark-curve signature `[r, s]` against a stored public key and returns the SRC-6
//! `'VALID'` sentinel, exactly like a standard account.

#[starknet::contract]
pub mod MockAccount {
    use core::ecdsa::check_ecdsa_signature;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use crate::logics::committee_logic::ISRC6;

    #[storage]
    struct Storage {
        public_key: felt252,
    }

    #[constructor]
    fn constructor(ref self: ContractState, public_key: felt252) {
        self.public_key.write(public_key);
    }

    #[abi(embed_v0)]
    impl SRC6Impl of ISRC6<ContractState> {
        fn is_valid_signature(
            self: @ContractState, hash: felt252, signature: Array<felt252>,
        ) -> felt252 {
            let pk = self.public_key.read();
            if signature.len() == 2
                && check_ecdsa_signature(hash, pk, *signature.at(0), *signature.at(1)) {
                'VALID'
            } else {
                0
            }
        }
    }
}
