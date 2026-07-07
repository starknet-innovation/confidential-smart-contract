// Private-claim example for the confidential shard framework.
//
// app_state = [total_claimed, n, account_0, allocation_0, claimed_0, ...] — exactly
//             HEADER_LEN + n * ROW_WIDTH felts.
// public_input = [claimant].
//
// The allowlist table stays in private_input; the public output of a successful proof is
// [claimant, allocation, total_claimed_after] (so a claim reveals the claimant + amount).
//
// `nextState` is the off-chain MIRROR of src/logics/private_claim_logic.cairo::step and
// MUST stay row-for-row identical: same first-match rule, same length check, same
// successor layout. Keep ROW_WIDTH / HEADER_LEN in sync across both files.

import type { ShardState } from "../framework.ts";
import type { Example } from "./types.ts";

const ROW_WIDTH = 3;
const HEADER_LEN = 2;

export type ClaimRow = {
  account: bigint;
  allocation: bigint;
  claimed?: boolean;
};

type PrivateClaimAction = { claimant: bigint };

function encodeRows(rows: ClaimRow[]): bigint[] {
  return rows.flatMap((r) => [r.account, r.allocation, r.claimed ? 1n : 0n]);
}

function claimedCount(appState: bigint[]): bigint {
  const n = Number(appState[1]);
  let claimed = 0n;
  for (let i = 0; i < n; i += 1) {
    if (appState[HEADER_LEN + i * ROW_WIDTH + 2] !== 0n) claimed += 1n;
  }
  return claimed;
}

/** Confidential allowlist claim. Immutable — logic never changes. */
export function privateClaimExample(logicClassHash: bigint, rows: ClaimRow[], totalClaimed = 0n): Example {
  const initialAppState = [totalClaimed, BigInt(rows.length), ...encodeRows(rows)];

  return {
    name: "private-claim",
    logicClassHash,
    genesisState: (salt) => ({ logicClassHash, appState: [...initialAppState], salt }),
    buildPublicInput: (action) => [(action as PrivateClaimAction).claimant],
    nextState: (prev, action, newSalt) => {
      const claimant = (action as PrivateClaimAction).claimant;
      const n = Number(prev.appState[1]);
      if (prev.appState.length !== HEADER_LEN + n * ROW_WIDTH) {
        throw new Error("bad state length");
      }
      const nextAppState = [...prev.appState];

      for (let i = 0; i < n; i += 1) {
        const base = HEADER_LEN + i * ROW_WIDTH;
        if (prev.appState[base] !== claimant) continue;

        if (prev.appState[base + 2] !== 0n) throw new Error("already claimed");
        const allocation = prev.appState[base + 1];
        nextAppState[0] = prev.appState[0] + allocation;
        nextAppState[base + 2] = 1n;
        return { logicClassHash: prev.logicClassHash, appState: nextAppState, salt: newSalt };
      }

      throw new Error("claimant missing");
    },
    describe: (s) => {
      const n = s.appState[1];
      return `total_claimed=${s.appState[0]} claimed=${claimedCount(s.appState)}/${n} (logic=${"0x" + s.logicClassHash.toString(16)})`;
    },
  };
}
