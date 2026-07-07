// Parity tests for the private-claim off-chain mirror. The successor states asserted
// here are the SAME vectors exercised by the Cairo tests (tests/logics.cairo) and the
// framework dispatch test — if nextState drifts from src/logics/private_claim_logic.cairo
// the on-chain proof's new_root would no longer match, so these lock the two together.
//
// Run: npm test  (node --test with type stripping).

import { test } from "node:test";
import assert from "node:assert/strict";
import { privateClaimExample } from "./private_claim.ts";

const LOGIC = 0xCAFEn;
const SALT = 77n;
const NEW_SALT = 456n;

function twoRows() {
  return privateClaimExample(LOGIC, [
    { account: 0xAn, allocation: 100n },
    { account: 0xBn, allocation: 50n },
  ]);
}

test("genesis encodes the claim table", () => {
  const genesis = twoRows().genesisState(SALT);
  assert.deepEqual(genesis.appState, [0n, 2n, 0xAn, 100n, 0n, 0xBn, 50n, 0n]);
  assert.equal(genesis.salt, SALT);
  assert.equal(genesis.logicClassHash, LOGIC);
});

test("nextState matches the Cairo eligible-claim vector", () => {
  const ex = twoRows();
  const next = ex.nextState(ex.genesisState(SALT), { claimant: 0xBn }, NEW_SALT);
  // Same successor the framework dispatch test commits: [50, 2, 0xA,100,0, 0xB,50,1].
  assert.deepEqual(next.appState, [50n, 2n, 0xAn, 100n, 0n, 0xBn, 50n, 1n]);
  assert.equal(next.salt, NEW_SALT);
  assert.equal(next.logicClassHash, LOGIC);
});

test("only the first duplicate row is claimed", () => {
  const ex = privateClaimExample(LOGIC, [
    { account: 0xBn, allocation: 50n },
    { account: 0xBn, allocation: 70n },
  ]);
  const next = ex.nextState(ex.genesisState(SALT), { claimant: 0xBn }, NEW_SALT);
  assert.deepEqual(next.appState, [50n, 2n, 0xBn, 50n, 1n, 0xBn, 70n, 0n]);
});

test("claims accumulate across two transitions", () => {
  const ex = twoRows();
  const first = ex.nextState(ex.genesisState(SALT), { claimant: 0xAn }, NEW_SALT);
  const second = ex.nextState(first, { claimant: 0xBn }, 789n);
  assert.deepEqual(second.appState, [150n, 2n, 0xAn, 100n, 1n, 0xBn, 50n, 1n]);
});

test("double claim throws", () => {
  const ex = privateClaimExample(LOGIC, [{ account: 0xBn, allocation: 50n, claimed: true }], 50n);
  assert.throws(() => ex.nextState(ex.genesisState(SALT), { claimant: 0xBn }, NEW_SALT), /already claimed/);
});

test("missing claimant throws", () => {
  const ex = privateClaimExample(LOGIC, [{ account: 0xAn, allocation: 100n }]);
  assert.throws(() => ex.nextState(ex.genesisState(SALT), { claimant: 0xBn }, NEW_SALT), /claimant missing/);
});

test("malformed state length throws", () => {
  const ex = privateClaimExample(LOGIC, [{ account: 0xAn, allocation: 100n }]);
  // n=2 declares two rows but only one is present.
  const bad = { ...ex.genesisState(SALT), appState: [0n, 2n, 0xAn, 100n, 0n] };
  assert.throws(() => ex.nextState(bad, { claimant: 0xAn }, NEW_SALT), /state length/);
});

test("u128 overflow on total matches Cairo revert behavior", () => {
  const ex = privateClaimExample(LOGIC, [{ account: 0xBn, allocation: 1n }]);
  const MAX = (1n << 128n) - 1n;
  // total_claimed already at u128::MAX; adding allocation must throw (mirrors Cairo checked add)
  const bad = { ...ex.genesisState(SALT), appState: [MAX, 1n, 0xBn, 1n, 0n] };
  assert.throws(() => ex.nextState(bad, { claimant: 0xBn }, NEW_SALT), /u128 overflow/);
});
