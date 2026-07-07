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

const U128_MAX = (1n << 128n) - 1n;

function assertU128(x: bigint, label = "value") {
  if (x < 0n || x > U128_MAX) throw new Error(`${label} not u128`);
}

function checkedU128Add(a: bigint, b: bigint): bigint {
  assertU128(a, "lhs");
  assertU128(b, "rhs");
  const sum = a + b;
  if (sum > U128_MAX) throw new Error("u128 overflow");
  return sum;
}

/** app_state = [count]; public_input = [step]. Immutable — logic never changes. */
export function counterExample(logicClassHash: bigint, initialCount = 0n): Example {
  return {
    name: "counter",
    logicClassHash,
    genesisState: (salt) => ({ logicClassHash, appState: [initialCount], salt }),
    buildPublicInput: (action) => [(action as CounterAction).step],
    nextState: (prev, action, newSalt) => {
      const step = (action as CounterAction).step;
      assertU128(prev.appState[0], "count");
      assertU128(step, "step");
      return {
        logicClassHash: prev.logicClassHash, // immutable: successor is always the same logic
        appState: [checkedU128Add(prev.appState[0], step)], // count += step (checked, matches Cairo)
        salt: newSalt, // rotated blinding
      };
    },
    describe: (s) => `count=${s.appState[0]} (logic=${"0x" + s.logicClassHash.toString(16)})`,
  };
}
