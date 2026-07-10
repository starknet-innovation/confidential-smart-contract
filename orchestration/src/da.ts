// Off-chain side of the encrypted-DA kit — the STARK-curve ECIES that matches
// src/crypto_kit.cairo / src/da_kit.cairo. Encryption happens IN-CIRCUIT (the logic's
// `step` calls `da_kit::seal`), so off-chain a party only ever DECRYPTS: read the latest
// `Transitioned` event's `outputs` blob, `open` it with their stark account key, and verify
// `commit(state) == root`. Keys ARE the parties' stark account keys (same curve as
// is_valid_signature) — no separate key material.
//
// Interop with the Cairo side is verified (a Cairo-sealed blob decrypts here).

import { ec, hash, shortString } from "starknet";

// STARK field prime.
const P = 2n ** 251n + 17n * 2n ** 192n + 1n;
const mod = (x: bigint) => ((x % P) + P) % P;

const KEY_DOMAIN = BigInt(shortString.encodeShortString("CS-DA-KEY"));
const CTR_DOMAIN = BigInt(shortString.encodeShortString("CS-DA-CTR"));
const MAC_DOMAIN = BigInt(shortString.encodeShortString("CS-DA-MAC"));
const pos = (xs: bigint[]) => BigInt(hash.computePoseidonHashOnElements(xs.map((x) => "0x" + x.toString(16))));

/** x-coordinate of a stark public key for a private scalar — a recipient key (matches `pubkey_x`). */
export function pubkeyX(priv: bigint): bigint {
  return BigInt(ec.starkCurve.getStarkKey("0x" + priv.toString(16)));
}

/**
 * Decrypt the `outputs` blob as party `index` with their stark private scalar, recovering
 * the felt array the logic sealed. Throws on a bad MAC (tampering / wrong key). Blob layout
 * matches `crypto_kit::ecies_encrypt`: [rx, ry, n, len, {ct[0..len], tag} per recipient].
 */
export function open(blob: bigint[], recipientPriv: bigint, index: number, nonce: bigint): bigint[] {
  const R = ec.starkCurve.ProjectivePoint.fromAffine({ x: blob[0], y: blob[1] });
  const sx = R.multiply(recipientPriv).toAffine().x; // S = priv·R = eph·P ⇒ shared x
  const key = pos([KEY_DOMAIN, sx]);
  const len = Number(blob[3]);
  const base = 4 + index * (len + 1);
  const ct = blob.slice(base, base + len);
  const tag = blob[base + len];
  if (pos([MAC_DOMAIN, key, nonce, ...ct]) !== tag) throw new Error("da: bad tag (tamper or wrong key)");
  return ct.map((c, j) => mod(c - pos([CTR_DOMAIN, key, nonce, BigInt(j)])));
}
