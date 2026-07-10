// The off-chain half of an application: a typed `Logic<State, Action>`.
//
// This is the ONE thing an app author writes on the TypeScript side. It is the exact
// mirror of the Cairo `ILogic::step` your shard commits to (see src/interfaces.cairo and
// the authoring kit in src/logic_kit.cairo): given a typed state and a typed action, it
// says how the state evolves and how to encode both into the felts the proof will carry.
//
// The framework SDK (./encoding.ts, ./shard.ts) knows nothing about your State/Action —
// it only ever sees felt arrays. `Logic` is the typed boundary between the two, so your
// app code stays in domain types and the wire encoding stays in one reviewable place.

/**
 * The off-chain definition of a confidential application.
 *
 * `State` is your domain view of `app_state` (e.g. `{ count }`). `Action` is one input to
 * a transition (e.g. `{ step }`). The four required members must agree with your Cairo
 * `ILogic` byte-for-byte:
 *  - `encodeState`/`decodeState` <-> the `app_state: Array<felt252>` layout your `step` reads.
 *  - `buildPublicInput` <-> the `public_input: Array<felt252>` your `step` deserializes.
 *  - `next` <-> the successor `app_state` your `step` returns (the OFF-CHAIN mirror, so the
 *    SDK can pre-compute `new_root` and pre-check the proof before broadcasting).
 */
export type Logic<State, Action> = {
  /** Short label (used in prover job labels / logs). */
  name: string;
  /** Class hash of the declared Cairo class implementing `ILogic::step` for this app. */
  logicClassHash: bigint;

  /** Typed state -> `app_state` felts. MUST match the Cairo layout your `step` reads. */
  encodeState(state: State): bigint[];
  /** `app_state` felts -> typed state. Inverse of `encodeState`. */
  decodeState(felts: bigint[]): State;

  /** Build the `public_input` felts for one transition from a typed action. */
  buildPublicInput(action: Action): bigint[];

  /**
   * Off-chain mirror of the on-chain `step`'s successor `app_state`: given the current
   * typed state and the action, return the next typed state. Pure — no I/O. The SDK uses
   * it to compute the expected `new_root` and pre-check the proof before broadcasting.
   */
  next(prev: State, action: Action): State;

  /**
   * OPTIONAL — for UPGRADEABLE logics only. Return the successor `logic_class_hash` this
   * transition installs. Omit (or return `current`) to self-perpetuate (the immutable
   * default that all reference logics use). If your Cairo `step` can return a DIFFERENT
   * class hash under its own authorization, mirror that choice here so the pre-checked
   * `new_root` matches the proof.
   */
  nextClassHash?(prev: State, action: Action, current: bigint): bigint;

  /** Human-readable one-liner for logs. */
  describe(state: State): string;
};

/**
 * Identity helper for defining a `Logic` with full type inference on `State`/`Action`.
 * Purely ergonomic — `defineLogic({...})` gives you checked members without restating
 * the generic parameters.
 */
export function defineLogic<State, Action>(logic: Logic<State, Action>): Logic<State, Action> {
  return logic;
}
