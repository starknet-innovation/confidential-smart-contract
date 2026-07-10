//! Test-only mock ERC-20. NOT part of the framework's trust surface — it exists solely
//! so snforge can exercise `balance_of`, outbox-`consume` (`transfer`), and inbox
//! (`transfer_from` for `deposit` / the intent fee) paths without a real token. Lives
//! under `mocks/`, which the cairo-auditor prunes. It tracks a single holder balance so
//! `deposit`'s balance-delta accounting can be exercised, supports an optional transfer
//! fee (to model fee-on-transfer tokens), and records the last call for assertions.

use starknet::ContractAddress;

#[starknet::interface]
pub trait IMockERC20<TContractState> {
    fn balance_of(self: @TContractState, account: ContractAddress) -> u256;
    fn transfer(ref self: TContractState, recipient: ContractAddress, amount: u256) -> bool;
    fn transfer_from(
        ref self: TContractState,
        sender: ContractAddress,
        recipient: ContractAddress,
        amount: u256,
    ) -> bool;
    fn set_balance(ref self: TContractState, bal: u256);
    /// Fee (absolute, in token units) deducted from each `transfer_from` credit — models
    /// a fee-on-transfer token: the holder receives `amount - fee`.
    fn set_transfer_fee(ref self: TContractState, fee: u256);
    fn last_from(self: @TContractState) -> ContractAddress;
    fn last_recipient(self: @TContractState) -> ContractAddress;
    fn last_amount(self: @TContractState) -> u256;
}

#[starknet::contract]
pub mod MockERC20 {
    use starknet::ContractAddress;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};

    // Single-holder model: `bal` is the balance of whichever account the framework
    // reads/credits (the shard). `transfer_from` credits it, `transfer` debits it.
    #[storage]
    struct Storage {
        bal: u256,
        fee: u256,
        last_from: ContractAddress,
        last_recipient: ContractAddress,
        last_amount: u256,
    }

    #[constructor]
    fn constructor(ref self: ContractState, initial_balance: u256) {
        self.bal.write(initial_balance);
    }

    #[abi(embed_v0)]
    impl MockImpl of super::IMockERC20<ContractState> {
        fn balance_of(self: @ContractState, account: ContractAddress) -> u256 {
            self.bal.read()
        }
        fn transfer(ref self: ContractState, recipient: ContractAddress, amount: u256) -> bool {
            self.bal.write(self.bal.read() - amount);
            self.last_recipient.write(recipient);
            self.last_amount.write(amount);
            true
        }
        fn transfer_from(
            ref self: ContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256,
        ) -> bool {
            // Credit the holder net of any fee (fee-on-transfer model).
            self.bal.write(self.bal.read() + amount - self.fee.read());
            self.last_from.write(sender);
            self.last_recipient.write(recipient);
            self.last_amount.write(amount);
            true
        }
        fn set_balance(ref self: ContractState, bal: u256) {
            self.bal.write(bal);
        }
        fn set_transfer_fee(ref self: ContractState, fee: u256) {
            self.fee.write(fee);
        }
        fn last_from(self: @ContractState) -> ContractAddress {
            self.last_from.read()
        }
        fn last_recipient(self: @ContractState) -> ContractAddress {
            self.last_recipient.read()
        }
        fn last_amount(self: @ContractState) -> u256 {
            self.last_amount.read()
        }
    }
}
