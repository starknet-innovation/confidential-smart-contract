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
