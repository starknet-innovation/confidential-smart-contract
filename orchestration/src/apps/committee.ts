// The committee treasury as an app — THE reference outbox application: a confidential
// M-of-N committee whose threshold-approved decisions emit arbitrary public calls through
// the framework outbox. Mirrors src/logics/committee_logic.cairo byte-for-byte (verified
// by the `approval_hash_matches_offchain_snip12` Cairo test).
//
// Authentication is account-abstraction native: members are Starknet ACCOUNTS, and each
// approval is a SNIP-12 typed message the member's wallet signs (`wallet_signTypedData`);
// the logic verifies it with the member account's `is_valid_signature`. The orchestrator
// never touches key material.
//
// Confidential: the member set, threshold, WHO approved, and the nonce (all only in the
// commitment; approvals ride in public_input, seen only by the prover). Public: the
// resulting calls, once recorded/consumed.
//
// app_state    = [nonce, threshold, n_members, member_addr_1 .. member_addr_n]
// public_input = Serde(Array<PublicCall>) ++ Serde(Array<MemberSig>)

import { typedData as td, TypedDataRevision } from "starknet";
import { serializeActions, hashActions, hex, type PublicCall } from "../encoding.ts";
import { defineLogic, type Logic } from "../logic.ts";

/** SNIP-12 domain — MUST match CommitteeLogic::DOMAIN_NAME / DOMAIN_VERSION. */
export const COMMITTEE_DOMAIN_NAME = "ConfShardCommittee";
export const COMMITTEE_DOMAIN_VERSION = "1";

const APPROVAL_TYPES = {
  StarknetDomain: [
    { name: "name", type: "shortstring" },
    { name: "version", type: "shortstring" },
    { name: "chainId", type: "shortstring" },
    { name: "revision", type: "shortstring" },
  ],
  Approval: [
    { name: "shard", type: "ContractAddress" },
    { name: "nonce", type: "felt" },
    { name: "calls_hash", type: "felt" },
  ],
};

/** One member's approval: the member account + the signature its account accepts. */
export type MemberSig = { signer: bigint; signature: bigint[] };

/** Domain view of `app_state = [nonce, threshold, n, member_addrs…]`. */
export type CommitteeState = { nonce: bigint; threshold: bigint; members: bigint[]; seed: bigint };

/** One transition: the calls to execute + ≥threshold distinct-member approvals. */
export type CommitteeAction = { calls: PublicCall[]; approvals: MemberSig[] };

/** Serde(Array<MemberSig>) = [len, (signer, sig.len, ...sig) per member]. */
function serializeMemberSigs(sigs: MemberSig[]): bigint[] {
  const out: bigint[] = [BigInt(sigs.length)];
  for (const s of sigs) out.push(s.signer, BigInt(s.signature.length), ...s.signature);
  return out;
}

/**
 * Build the committee logic for a declared `CommitteeLogic` class hash. Immutable — the
 * reference ships no member-rotation path (`next` only advances the nonce). Provide the
 * member set + threshold as the initial `CommitteeState` when you deploy the shard.
 */
export function committeeLogic(logicClassHash: bigint): Logic<CommitteeState, CommitteeAction> {
  return defineLogic<CommitteeState, CommitteeAction>({
    name: "committee",
    logicClassHash,
    // v5 app_state = [nonce, threshold, n, members..., seed] (trailing salt_kit blinding).
    encodeState: (s) => [s.nonce, s.threshold, BigInt(s.members.length), ...s.members, s.seed],
    decodeState: (f) => {
      const n = Number(f[2]);
      return { nonce: f[0], threshold: f[1], members: f.slice(3, 3 + n), seed: f[3 + n] };
    },
    // public_input = Serde(Array<PublicCall>) ++ Serde(Array<MemberSig>)
    buildPublicInput: (a) => [...serializeActions(a.calls), ...serializeMemberSigs(a.approvals)],
    next: (prev) => ({ ...prev, nonce: prev.nonce + 1n }), // nonce++, committee + seed unchanged
    describe: (s) => `nonce=${s.nonce} threshold=${s.threshold} members=${s.members.length}`,
  });
}

/**
 * The SNIP-12 TypedData a member signs to approve `calls` on `shard` at `nonce`.
 * Hand this to the wallet's `wallet_signTypedData` for each member account; the returned
 * `[r, s]` (or whatever the account produces) becomes that member's `MemberSig.signature`.
 * `chainId` is a felt-encoded short string (e.g. "SN_SEPOLIA") or its hex felt.
 *
 * BLIND-SIGNING CAVEAT (audit): the message binds `calls_hash`, derived HERE from the
 * actual `calls`. Always build the typed data from the calls the member reviewed — never
 * sign a hash handed over by an untrusted party, since the wallet shows only the hash.
 */
export function approvalTypedData(shard: bigint, nonce: bigint, calls: PublicCall[], chainId: string) {
  return {
    types: APPROVAL_TYPES,
    primaryType: "Approval",
    domain: { name: COMMITTEE_DOMAIN_NAME, version: COMMITTEE_DOMAIN_VERSION, chainId, revision: "1" },
    message: { shard: hex(shard), nonce: hex(nonce), calls_hash: hex(hashActions(calls)) },
  };
}

/** Off-chain mirror of CommitteeLogic::approval_message_hash (for pre-checks / tests). */
export function approvalMessageHash(shard: bigint, nonce: bigint, calls: PublicCall[], chainId: string, signer: bigint): bigint {
  return BigInt(td.getMessageHash(approvalTypedData(shard, nonce, calls, chainId), hex(signer)));
}

export { TypedDataRevision };
