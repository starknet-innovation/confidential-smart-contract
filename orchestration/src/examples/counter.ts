// The counter as ONE example of a framework logic — a minimal, IMMUTABLE dummy.
// Everything counter-specific lives here; the framework SDK (../framework.ts) knows
// nothing about counters, and this reference ships no upgrade path (audit finding #2).
//
// To add a different application: write a new file like this describing how to encode
// its app_state / public_input and how its state transitions off-chain. An upgradeable
// app would additionally choose a *different* successor class hash in `nextState`
// (gated by its own authorization); this dummy always keeps its own logic.

import type { ShardState } from "../framework.ts";

/** The minimal contract an example must provide to the generic driver. */
export type Example = {
  name: string;
  /** Class hash of the logic implementing ILogic::step for this example. */
  logicClassHash: bigint;
  /** Build the initial ShardState (genesis). */
  genesisState(salt: bigint): ShardState;
  /** Build `public_input` for a transition. */
  buildPublicInput(action: unknown): bigint[];
  /**
   * Off-chain mirror of the on-chain logic `step`: given the current state, the action,
   * and a fresh `newSalt`, return the successor state the proof will commit. Lets the
   * caller track state and pre-check the proof's new_root before broadcasting.
   */
  nextState(prev: ShardState, action: unknown, newSalt: bigint): ShardState;
  /** Human-readable view of the app_state (for logging). */
  describe(s: ShardState): string;
};

type CounterAction = { step: bigint };

/** app_state = [count]; public_input = [step]. Immutable — logic never changes. */
export function counterExample(logicClassHash: bigint, initialCount = 0n): Example {
  return {
    name: "counter",
    logicClassHash,
    genesisState: (salt) => ({ logicClassHash, appState: [initialCount], salt }),
    buildPublicInput: (action) => [(action as CounterAction).step],
    nextState: (prev, action, newSalt) => ({
      logicClassHash: prev.logicClassHash, // immutable: successor is always the same logic
      appState: [prev.appState[0] + (action as CounterAction).step], // count += step
      salt: newSalt, // rotated blinding
    }),
    describe: (s) => `count=${s.appState[0]} (logic=${"0x" + s.logicClassHash.toString(16)})`,
  };
}
