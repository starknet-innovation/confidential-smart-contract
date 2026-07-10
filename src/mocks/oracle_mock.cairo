//! Test-only price oracle. NOT part of the framework's trust surface (pruned by the
//! cairo-auditor). Exposes `get_price()` (the selector `LendingLogic` reads via a proven
//! read) plus a `set_price` so tests can move the price to trigger origination bands and
//! liquidation. Price = loan-token units per 1 collateral unit, scaled by 1e18.

#[starknet::interface]
pub trait IMockOracle<TState> {
    fn get_price(self: @TState) -> u256;
    fn set_price(ref self: TState, price: u256);
}

#[starknet::contract]
pub mod MockOracle {
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};

    #[storage]
    struct Storage {
        price: u256,
    }

    #[constructor]
    fn constructor(ref self: ContractState, price: u256) {
        self.price.write(price);
    }

    #[abi(embed_v0)]
    impl MockOracleImpl of super::IMockOracle<ContractState> {
        fn get_price(self: @ContractState) -> u256 {
            self.price.read()
        }
        fn set_price(ref self: ContractState, price: u256) {
            self.price.write(price);
        }
    }
}
