// The counter as ONE app built on the framework — the minimal, IMMUTABLE reference.
//
// It shows the smallest possible `Logic`: a single-felt state, a single-felt action, a
// pure increment, and no outbox actions. Mirrors src/logics/counter_logic.cairo
// (app_state = [count]; public_input = [step]). Copy this shape (or the richer
// ./committee.ts) to build your own app — the SDK core never changes.

import { defineLogic, type Logic } from "../logic.ts";

/** Domain view of `app_state = [count]`. */
export type CounterState = { count: bigint };
/** One transition input: how much to add. */
export type CounterAction = { step: bigint };

/** Build the counter logic for a declared `CounterLogic` class hash. */
export function counterLogic(logicClassHash: bigint): Logic<CounterState, CounterAction> {
  return defineLogic<CounterState, CounterAction>({
    name: "counter",
    logicClassHash,
    encodeState: (s) => [s.count],
    decodeState: (f) => ({ count: f[0] }),
    buildPublicInput: (a) => [a.step],
    next: (prev, a) => ({ count: prev.count + a.step }), // immutable logic: self-perpetuates
    describe: (s) => `count=${s.count}`,
  });
}
