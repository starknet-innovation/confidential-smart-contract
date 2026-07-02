//! Unit tests for the reference `CounterLogic` (`step`) — a pure, immutable state
//! transition. Deploy the logic, call `step`, assert.

use snforge_std::{declare, ContractClassTrait, DeclareResultTrait};
use confidential_counter::interfaces::{ILogicDispatcher, ILogicDispatcherTrait};

fn deploy(name: ByteArray) -> ILogicDispatcher {
    let contract = declare(name).unwrap().contract_class();
    let (addr, _) = contract.deploy(@array![]).unwrap();
    ILogicDispatcher { contract_address: addr }
}

#[test]
fn counter_increments_and_self_perpetuates() {
    let logic = deploy("CounterLogic");
    let (next, new_state, outputs) = logic.step(0x123, array![5], array![3]);
    assert(next == 0x123, 'should keep own logic hash');
    assert(new_state.len() == 1, 'app_state len');
    assert(*new_state.at(0) == 8, 'count should be 8');
    assert(*outputs.at(0) == 3, 'output should be step');
}

#[test]
fn counter_is_immutable_ignores_upgrade_directive() {
    let logic = deploy("CounterLogic");
    // Even with an extra "upgrade" arg in public_input, the immutable dummy returns its
    // OWN class hash — it has no upgrade path.
    let (next, new_state, _) = logic.step(0xABC, array![5], array![3, 0x999]);
    assert(next == 0xABC, 'must stay immutable');
    assert(*new_state.at(0) == 8, 'count still advances');
}

#[test]
#[should_panic]
fn counter_reverts_on_u128_overflow() {
    let logic = deploy("CounterLogic");
    // u128::MAX + 1 must panic (no felt252 wraparound) — addresses audit finding #1.
    logic.step(0x1, array![0xffffffffffffffffffffffffffffffff], array![1]);
}
