//! The confidential shard framework as a reusable `#[starknet::component]`.
//!
//! This is the framework's guts — the minimal, logic-agnostic verifier + dispatcher —
//! factored out so it can be EMBEDDED by more than one contract. The canonical
//! `ConfidentialShard` (src/framework.cairo) is a thin contract that embeds this and adds
//! NOTHING: it stays frozen and address-pinned, the verifiable trust root. A deployer who
//! wants a DIFFERENT posture (e.g. an upgradeable variant) embeds this SAME audited
//! component and adds their own wrapper (e.g. a self-gated `replace_class`) — so their
//! users audit only the thin wrapper, not the core. Upgradeability is therefore an opt-in
//! property of a deployer's variant, never of the blessed component.
//!
//! Behaviour is IDENTICAL to the pre-component monolith (the framework tests pin it).
//!
//! It NEVER chooses the logic: `transition` `library_call`s whatever `logic_class_hash` is
//! committed in the state and relays the successor. `apply_transition` = proof<->message
//! binding + CAS; it records any `actions` to an outbox that a permissionless `consume`
//! executes later. v4 adds the inbox (`deposit`/`register_intent` + proven-read views), the
//! `outbox_of` view, a freshness gate, and echoes `outputs` in `Transitioned`.
//!
//! DO NOT add `replace_class`, an owner/admin, or a `root` setter to THIS component or to
//! the canonical contract — the frozen-and-address-pinned core is what makes a shard's
//! logic-immutability real.

#[starknet::component]
pub mod ShardComponent {
    use core::poseidon::poseidon_hash_span;
    use starknet::{ContractAddress, get_contract_address, get_caller_address, get_block_info};
    use starknet::syscalls::{
        send_message_to_l1_syscall, get_execution_info_v3_syscall, call_contract_syscall,
    };
    use starknet::SyscallResultTrait;
    use starknet::storage::{
        StoragePointerReadAccess, StoragePointerWriteAccess, Map, StorageMapReadAccess,
        StorageMapWriteAccess, StoragePathEntry, Vec, VecTrait, MutableVecTrait,
    };
    use crate::interfaces::{
        IShard, ShardState, PublicMessage, PublicCall, InboxEntry, INBOX_KIND_DEPOSIT,
        INBOX_KIND_INTENT, ILogicLibraryDispatcher, ILogicDispatcherTrait, IERC20Dispatcher,
        IERC20DispatcherTrait,
    };

    const PROOF_FACTS_N_MSG_INDEX: usize = 7;
    const PROOF_FACTS_MSG_HASH_INDEX: usize = 8;
    const PROOF_FACTS_REF_BLOCK_INDEX: usize = 4;
    const MSG_TO_ADDRESS: felt252 = 0;
    const MAX_INTENT_PAYLOAD: u32 = 64;

    #[storage]
    pub struct Storage {
        root: felt252,
        outbox: Map<felt252, felt252>,
        inbox_size: u64,
        inbox_kind: Map<u64, felt252>,
        inbox_caller: Map<u64, ContractAddress>,
        inbox_block: Map<u64, u64>,
        inbox_data: Map<u64, Vec<felt252>>,
        freshness_window: u64,
        intent_fee_token: ContractAddress,
        intent_fee_amount: u256,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        Transitioned: Transitioned,
        OutboxRecorded: OutboxRecorded,
        OutboxConsumed: OutboxConsumed,
        InboxAppended: InboxAppended,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Transitioned {
        #[key]
        pub old_root: felt252,
        pub new_root: felt252,
        pub outputs: Array<felt252>,
    }

    #[derive(Drop, starknet::Event)]
    pub struct OutboxRecorded {
        #[key]
        pub entry_key: felt252,
        pub actions_hash: felt252,
    }

    #[derive(Drop, starknet::Event)]
    pub struct OutboxConsumed {
        #[key]
        pub entry_key: felt252,
    }

    #[derive(Drop, starknet::Event)]
    pub struct InboxAppended {
        #[key]
        pub seq: u64,
        pub kind: felt252,
        pub caller: ContractAddress,
    }

    #[embeddable_as(ShardImpl)]
    pub impl Shard<
        TContractState, +HasComponent<TContractState>,
    > of IShard<ComponentState<TContractState>> {
        fn transition(
            ref self: ComponentState<TContractState>,
            public_input: Array<felt252>,
            private_input: ShardState,
        ) {
            let ShardState { logic_class_hash, app_state } = private_input;
            let old_root = commit(logic_class_hash, @app_state);
            let logic = ILogicLibraryDispatcher {
                class_hash: logic_class_hash.try_into().expect('bad logic class hash'),
            };
            let (next_logic_class_hash, new_app_state, outputs, actions) = logic
                .step(logic_class_hash, app_state, public_input);
            assert!(next_logic_class_hash != 0, "next_logic_zero");
            let new_root = commit(next_logic_class_hash, @new_app_state);
            let msg = PublicMessage { old_root, new_root, outputs, actions };
            let mut payload: Array<felt252> = array![];
            msg.serialize(ref payload);
            send_message_to_l1_syscall(MSG_TO_ADDRESS, payload.span()).unwrap_syscall();
        }

        fn apply_transition(ref self: ComponentState<TContractState>, msg: PublicMessage) {
            let exec = get_execution_info_v3_syscall().unwrap_syscall().unbox();
            let tx_info = exec.tx_info.unbox();
            let proof_facts = tx_info.proof_facts;

            assert(*proof_facts.at(PROOF_FACTS_N_MSG_INDEX) == 1, 'expected 1 message');
            let h = compute_message_hash(get_contract_address(), @msg);
            assert(*proof_facts.at(PROOF_FACTS_MSG_HASH_INDEX) == h, 'proof/msg mismatch');

            let window = self.freshness_window.read();
            if window != 0 {
                let ref_block: u64 = (*proof_facts.at(PROOF_FACTS_REF_BLOCK_INDEX))
                    .try_into()
                    .expect('bad ref block fact');
                let now = get_block_info().unbox().block_number;
                assert(now <= ref_block + window, 'stale reference block');
            }

            let PublicMessage { old_root, new_root, outputs, actions } = msg;
            assert(old_root == self.root.read(), 'stale root');
            self.root.write(new_root);
            self.emit(Transitioned { old_root, new_root, outputs });

            if actions.len() != 0 {
                let actions_hash = hash_actions(@actions);
                self.outbox.write(new_root, actions_hash);
                self.emit(OutboxRecorded { entry_key: new_root, actions_hash });
            }
        }

        fn consume(
            ref self: ComponentState<TContractState>, entry_key: felt252, actions: Array<PublicCall>,
        ) {
            let stored = self.outbox.read(entry_key);
            assert(stored != 0, 'nothing to consume');
            assert(hash_actions(@actions) == stored, 'actions mismatch');
            self.outbox.write(entry_key, 0);
            let this = get_contract_address();
            for a in actions {
                assert(a.to != this, 'self-call');
                call_contract_syscall(a.to, a.selector, a.calldata.span()).unwrap_syscall();
            };
            self.emit(OutboxConsumed { entry_key });
        }

        fn deposit(
            ref self: ComponentState<TContractState>,
            token: ContractAddress,
            amount: u256,
            note: felt252,
        ) {
            assert(amount != 0_u256, 'zero deposit');
            let caller = get_caller_address();
            let erc20 = IERC20Dispatcher { contract_address: token };
            let this = get_contract_address();
            let before = erc20.balance_of(this);
            let ok = erc20.transfer_from(caller, this, amount);
            assert(ok, 'transfer_from failed');
            let received = erc20.balance_of(this) - before;
            assert(received != 0_u256, 'no funds received');
            self
                .append_inbox(
                    INBOX_KIND_DEPOSIT,
                    caller,
                    array![token.into(), received.low.into(), received.high.into(), note],
                );
        }

        fn register_intent(ref self: ComponentState<TContractState>, payload: Array<felt252>) {
            assert(payload.len() <= MAX_INTENT_PAYLOAD, 'payload too long');
            let caller = get_caller_address();
            let fee = self.intent_fee_amount.read();
            if fee != 0_u256 {
                let ok = IERC20Dispatcher { contract_address: self.intent_fee_token.read() }
                    .transfer_from(caller, get_contract_address(), fee);
                assert(ok, 'intent fee failed');
            }
            self.append_inbox(INBOX_KIND_INTENT, caller, payload);
        }

        fn inbox_len(self: @ComponentState<TContractState>) -> u64 {
            self.inbox_size.read()
        }

        fn inbox_entry(self: @ComponentState<TContractState>, seq: u64) -> InboxEntry {
            assert(seq < self.inbox_size.read(), 'inbox out of range');
            let vec = self.inbox_data.entry(seq);
            let mut data: Array<felt252> = array![];
            let n = vec.len();
            let mut i: u64 = 0;
            while i != n {
                data.append(vec.at(i).read());
                i += 1;
            };
            InboxEntry {
                kind: self.inbox_kind.read(seq),
                caller: self.inbox_caller.read(seq),
                block_number: self.inbox_block.read(seq),
                data,
            }
        }

        fn outbox_of(self: @ComponentState<TContractState>, entry_key: felt252) -> felt252 {
            self.outbox.read(entry_key)
        }

        fn get_root(self: @ComponentState<TContractState>) -> felt252 {
            self.root.read()
        }
    }

    #[generate_trait]
    pub impl InternalImpl<
        TContractState, +HasComponent<TContractState>,
    > of InternalTrait<TContractState> {
        /// Genesis initializer — call from the embedding contract's constructor.
        fn initializer(
            ref self: ComponentState<TContractState>,
            genesis_root: felt252,
            freshness_window: u64,
            intent_fee_token: ContractAddress,
            intent_fee_amount: u256,
        ) {
            assert!(genesis_root != 0, "genesis_root_zero");
            if intent_fee_amount != 0_u256 {
                assert!(intent_fee_token.into() != 0_felt252, "fee_token_zero");
            }
            self.root.write(genesis_root);
            self.freshness_window.write(freshness_window);
            self.intent_fee_token.write(intent_fee_token);
            self.intent_fee_amount.write(intent_fee_amount);
        }

        fn append_inbox(
            ref self: ComponentState<TContractState>,
            kind: felt252,
            caller: ContractAddress,
            data: Array<felt252>,
        ) {
            let seq = self.inbox_size.read();
            self.inbox_kind.write(seq, kind);
            self.inbox_caller.write(seq, caller);
            self.inbox_block.write(seq, get_block_info().unbox().block_number);
            let mut vec = self.inbox_data.entry(seq);
            for x in data {
                vec.push(x);
            };
            self.inbox_size.write(seq + 1);
            self.emit(InboxAppended { seq, kind, caller });
        }
    }

    /// Commitment over the FULL confidential state, INCLUDING the logic class hash.
    /// v5: `[logic_class_hash, app_state.len, ...app_state]` — NO framework salt (blinding
    /// is a logic-level field inside app_state; see salt_kit). Byte-identical off-chain.
    pub fn commit(logic_class_hash: felt252, app_state: @Array<felt252>) -> felt252 {
        let mut data: Array<felt252> = array![logic_class_hash, app_state.len().into()];
        for x in app_state.span() {
            data.append(*x);
        };
        poseidon_hash_span(data.span())
    }

    fn hash_actions(actions: @Array<PublicCall>) -> felt252 {
        let mut data: Array<felt252> = array![];
        actions.serialize(ref data);
        poseidon_hash_span(data.span())
    }

    fn compute_message_hash(from: ContractAddress, msg: @PublicMessage) -> felt252 {
        let mut payload: Array<felt252> = array![];
        msg.serialize(ref payload);
        let mut data: Array<felt252> = array![from.into(), MSG_TO_ADDRESS, payload.len().into()];
        for f in payload.span() {
            data.append(*f);
        };
        poseidon_hash_span(data.span())
    }
}
