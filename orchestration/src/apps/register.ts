// PrivateRegister — the SDK face of the da_kit example (src/logics/register_logic.cairo).
//
// A confidential `value` blind parties learn ONLY by decrypting the in-circuit-sealed DA.
// The seal is computed in Cairo `step`; off-chain a party recovers the state with `da.open`
// (their stark account key) and verifies it via `commit(state) == root`. This is the
// blind-party case salt_kit can't cover.

import { commit, freshSalt, type ShardState } from "../encoding.ts";
import { defineLogic, type Logic } from "../logic.ts";
import { open, pubkeyX } from "../da.ts";

/** app_state = [nonce, value, seed, n_parties, key_1..key_n] (keys = parties' stark pubkey x). */
export type RegisterState = { nonce: bigint; value: bigint; seed: bigint; parties: bigint[] };

/** Set a new value; `eph` is a fresh ECIES ephemeral scalar (e.g. `freshSalt()`). */
export type RegisterAction = { kind: "set"; newValue: bigint; eph: bigint };

export function registerLogic(logicClassHash: bigint): Logic<RegisterState, RegisterAction> {
  return defineLogic<RegisterState, RegisterAction>({
    name: "register",
    logicClassHash,
    encodeState: (s) => [s.nonce, s.value, s.seed, BigInt(s.parties.length), ...s.parties],
    decodeState: (f) => ({ nonce: f[0], value: f[1], seed: f[2], parties: f.slice(4, 4 + Number(f[3])) }),
    buildPublicInput: (a) => [a.newValue, a.eph],
    next: (prev, a) => ({ ...prev, nonce: prev.nonce + 1n, value: a.newValue }), // seed+parties carried
    describe: (s) => `nonce=${s.nonce} parties=${s.parties.length} (value sealed to each)`,
  });
}

/** Genesis state. `partyPrivs` are the parties' stark private scalars; their pubkey x-coords
 *  become the da_kit recipients. `seed` is the salt_kit blinding (e.g. `freshSalt()`). */
export function newRegister(value: bigint, partyPrivs: bigint[], seed: bigint): RegisterState {
  return { nonce: 0n, value, seed, parties: partyPrivs.map(pubkeyX) };
}

/**
 * ESCAPE / resume: a party decrypts the latest `outputs` blob with their stark private scalar
 * (index = their position in `parties`), recovers the full state, and verifies it commits to
 * `onchainRoot`. Returns the reconstructed ShardState (ready to self-prove). Throws on a bad
 * tag (wrong key / tamper) or a root mismatch (a malicious operator would be caught here).
 */
export function resumeRegister(
  logic: Logic<RegisterState, RegisterAction>, outputs: bigint[], myPriv: bigint, index: number, nonce: bigint, onchainRoot: bigint,
): { state: RegisterState; shardState: ShardState } {
  const appState = open(outputs, myPriv, index, nonce);
  const shardState: ShardState = { logicClassHash: logic.logicClassHash, appState };
  if (commit(shardState) !== onchainRoot) throw new Error("recovered state does not match on-chain root");
  return { state: logic.decodeState(appState), shardState };
}

export { freshSalt };
