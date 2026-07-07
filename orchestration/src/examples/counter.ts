// The counter as ONE example of a framework logic — a minimal, IMMUTABLE dummy.
// Everything counter-specific lives here; the framework SDK (../framework.ts) knows
// nothing about counters, and this reference ships no upgrade path (audit finding #2).
//
// To add a different application: write a new file like this describing how to encode
// its app_state / public_input and how its state transitions off-chain. An upgradeable
// app would additionally choose a *different* successor class hash in `nextState`
// (gated by its own authorization); this dummy always keeps its own logic.

import type { Example } from "./types.ts";

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
