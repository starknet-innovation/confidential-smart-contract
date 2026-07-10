// Confidential P2P lending as an app (v3 — v5 framework + salt_kit escape hatch).
//
// Mirrors src/logics/lending_logic.cairo: 21-felt app_state where [20] is a salt_kit `seed`
// (the blinding), and every transition carries a SNIP-12 signature verified in-proof. Because
// v5 has no framework salt and `step` carries the seed, ANY party who knows the terms (they
// agreed them) + the seed can reconstruct every state and self-prove — even against a
// MALICIOUS operator. No cipher, no crypto (that's da_kit, for the blind-party case).
//
// take = borrower-signed; close = signed by any of {operator, lender, borrower}. The proven
// guards (band at take; repay/liquidate/expiry at close) still constrain the outcome.

import { hash, typedData as td, shortString } from "starknet";
import { commit, type ShardState } from "../encoding.ts";
import { defineLogic, type Logic } from "../logic.ts";
import type { MemberSig } from "./committee.ts";

export const OFFERED = 0n;
export const ACTIVE = 1n;
export const CLOSED = 2n;
export const PRICE_SCALE = 1_000_000_000_000_000_000n;
export const BPS = 10_000n;

const MASK = (1n << 128n) - 1n;
const lo = (x: bigint) => x & MASK;
const hi = (x: bigint) => x >> 128n;
const u256 = (a: bigint, b: bigint) => (b << 128n) | a;

/** SNIP-12 domain — MUST match LendingLogic::DOMAIN_NAME / DOMAIN_VERSION. */
export const LENDING_DOMAIN_NAME = "ConfShardLending";
export const LENDING_DOMAIN_VERSION = "1";
export const OP_TAKE = shortString.encodeShortString("TAKE");
export const OP_CLOSE = shortString.encodeShortString("CLOSE");
export const OP_CANCEL = shortString.encodeShortString("CANCEL");

/** Domain view of the 21-felt lending app_state (v5: [20] = salt_kit seed). */
export type LendingState = {
  status: bigint;
  lender: bigint;
  borrower: bigint;
  collateralToken: bigint;
  loanToken: bigint;
  oracle: bigint;
  principal: bigint;
  minLtvBps: bigint; // HIDDEN
  maxLtvBps: bigint; // HIDDEN
  rateBps: bigint;
  duration: bigint;
  debt: bigint;
  collateral: bigint;
  startTime: bigint;
  inboxSeen: bigint;
  operator: bigint; // authorized alongside lender/borrower
  nonce: bigint; // single-use signature counter
  seed: bigint; // salt_kit blinding — shared with parties so they can reconstruct + self-prove
};

/** All variants carry the authorizing signature; take also carries observed fields. `cancel`
 *  is lender-signed on an OFFERED loan (before anyone takes it) and refunds the escrow. */
export type LendingAction =
  | { kind: "take"; draw: bigint; collateral: bigint; borrower: bigint; startTime: bigint; inboxSeen: bigint; auth: MemberSig }
  | { kind: "close"; auth: MemberSig }
  | { kind: "cancel"; auth: MemberSig };

/** poseidon(op, amount.low, amount.high) — the action digest bound into the SNIP-12 message. */
export function actionDigest(op: bigint, amount: bigint): bigint {
  return BigInt(hash.computePoseidonHashOnElements([op, lo(amount), hi(amount)]));
}

/** Build the lending logic for a declared `LendingLogic` class hash. */
export function lendingLogic(logicClassHash: bigint): Logic<LendingState, LendingAction> {
  return defineLogic<LendingState, LendingAction>({
    name: "lending",
    logicClassHash,
    encodeState: (s) => [
      s.status, s.lender, s.borrower, s.collateralToken, s.loanToken, s.oracle,
      lo(s.principal), hi(s.principal), s.minLtvBps, s.maxLtvBps, s.rateBps, s.duration,
      lo(s.debt), hi(s.debt), lo(s.collateral), hi(s.collateral),
      s.startTime, s.inboxSeen, s.operator, s.nonce, s.seed,
    ],
    decodeState: (f) => ({
      status: f[0], lender: f[1], borrower: f[2], collateralToken: f[3], loanToken: f[4], oracle: f[5],
      principal: u256(f[6], f[7]), minLtvBps: f[8], maxLtvBps: f[9], rateBps: f[10], duration: f[11],
      debt: u256(f[12], f[13]), collateral: u256(f[14], f[15]), startTime: f[16], inboxSeen: f[17],
      operator: f[18], nonce: f[19], seed: f[20],
    }),
    // public_input = Serde(draw: u256) ++ Serde(auth: MemberSig)  (v3 — no cipher)
    buildPublicInput: (a) => {
      const draw = a.kind === "take" ? a.draw : 0n;
      return [lo(draw), hi(draw), a.auth.signer, BigInt(a.auth.signature.length), ...a.auth.signature];
    },
    next: (prev, a) =>
      a.kind === "take"
        ? { ...prev, status: ACTIVE, borrower: a.borrower, debt: a.draw, collateral: a.collateral, startTime: a.startTime, inboxSeen: a.inboxSeen, nonce: prev.nonce + 1n }
        : { ...prev, status: CLOSED, nonce: prev.nonce + 1n }, // seed carried via ...prev
    describe: (s) => {
      const st = s.status === OFFERED ? "OFFERED" : s.status === ACTIVE ? "ACTIVE" : "CLOSED";
      return `${st} nonce=${s.nonce} debt=${s.debt} collateral=${s.collateral} (min ${s.minLtvBps}bps / max ${s.maxLtvBps}bps hidden)`;
    },
  });
}

/** Build the genesis (OFFERED) state. `operator` joins {lender, borrower} as an authorized
 *  signer. `seed` is the salt_kit blinding — a high-entropy value (e.g. `freshSalt()`) agreed
 *  at origination and shared with the parties so they can reconstruct state to self-prove. */
export function offer(terms: {
  lender: bigint;
  operator: bigint;
  collateralToken: bigint;
  loanToken: bigint;
  oracle: bigint;
  principal: bigint;
  minLtvBps: bigint;
  maxLtvBps: bigint;
  rateBps: bigint;
  duration: bigint;
  seed: bigint;
}): LendingState {
  return {
    status: OFFERED, lender: terms.lender, borrower: 0n,
    collateralToken: terms.collateralToken, loanToken: terms.loanToken, oracle: terms.oracle,
    principal: terms.principal, minLtvBps: terms.minLtvBps, maxLtvBps: terms.maxLtvBps,
    rateBps: terms.rateBps, duration: terms.duration,
    debt: 0n, collateral: 0n, startTime: 0n, inboxSeen: 0n,
    operator: terms.operator, nonce: 0n, seed: terms.seed,
  };
}

const LOAN_ACTION_TYPES = {
  StarknetDomain: [
    { name: "name", type: "shortstring" }, { name: "version", type: "shortstring" },
    { name: "chainId", type: "shortstring" }, { name: "revision", type: "shortstring" },
  ],
  LoanAction: [
    { name: "shard", type: "ContractAddress" }, { name: "nonce", type: "felt" }, { name: "action_digest", type: "felt" },
  ],
};

/**
 * The SNIP-12 TypedData a party signs to authorize a transition. `op` is `OP_TAKE`/`OP_CLOSE`;
 * `amount` is the draw for take (0 for close). Hand to `wallet_signTypedData` for the signer's
 * account; the returned `[r, s]` becomes the `MemberSig.signature`.
 */
export function loanActionTypedData(shard: bigint, nonce: bigint, op: bigint, amount: bigint, chainId: string) {
  const hex = (x: bigint) => "0x" + x.toString(16);
  return {
    types: LOAN_ACTION_TYPES,
    primaryType: "LoanAction",
    domain: { name: LENDING_DOMAIN_NAME, version: LENDING_DOMAIN_VERSION, chainId, revision: "1" },
    message: { shard: hex(shard), nonce: hex(nonce), action_digest: hex(actionDigest(op, amount)) },
  };
}

/** Off-chain mirror of LendingLogic::loan_action_message_hash (for pre-checks / tests). */
export function loanActionMessageHash(shard: bigint, nonce: bigint, op: bigint, amount: bigint, chainId: string, signer: bigint): bigint {
  return BigInt(td.getMessageHash(loanActionTypedData(shard, nonce, op, amount, chainId), "0x" + signer.toString(16)));
}

/**
 * ESCAPE HELPER — reconstruct the current confidential state from the agreed terms + the
 * shared `seed`, and VERIFY it against the on-chain root. A party runs this to rebuild the
 * exact `ShardState` and self-prove a close without the operator (v5: no cipher needed —
 * the seed is the only non-public input, and the parties hold it). Throws on mismatch.
 */
export function resumeState(logic: Logic<LendingState, LendingAction>, state: LendingState, onchainRoot: bigint): ShardState {
  const s: ShardState = { logicClassHash: logic.logicClassHash, appState: logic.encodeState(state) };
  if (commit(s) !== onchainRoot) throw new Error("reconstructed state does not match on-chain root");
  return s;
}

/** True iff `draw` against `collateral` at `price` lands in the hidden band [min, max). */
export function originationOk(draw: bigint, collateral: bigint, price: bigint, minLtvBps: bigint, maxLtvBps: bigint): boolean {
  const vprime = collateral * price;
  const drawScaled = draw * PRICE_SCALE * BPS;
  return minLtvBps * vprime <= drawScaled && drawScaled < maxLtvBps * vprime;
}

/** Total owed at close: principal drawn + flat term interest. */
export function owed(debt: bigint, rateBps: bigint): bigint {
  return debt + (debt * rateBps) / BPS;
}
