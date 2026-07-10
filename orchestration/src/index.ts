// Public API of the confidential shard SDK.
//
// Build an app in three pieces:
//   1. A Cairo `ILogic` class (see src/logics/*.cairo + the authoring kit src/logic_kit.cairo),
//      declared on-chain.
//   2. A typed `Logic<State, Action>` mirroring it (./logic.ts; ./apps/* are references).
//   3. A `ShardBackend` — use the shipped `StrkdBackend`, or implement your own.
//
// Then: `deployShard({...})` -> `shard.transition(action)`. That's the whole loop.
//
//   import { StrkdBackend, deployShard } from "confidential-shard-sdk";
//   import { counterLogic } from "confidential-shard-sdk/apps/counter";
//
//   const backend = new StrkdBackend(strkd, account);
//   const { shard } = await deployShard({
//     backend, frameworkClassHash, logic: counterLogic(logicClassHash),
//     initial: { count: 0n }, deploySalt: 1n,
//   });
//   await shard.transition({ step: 1n });   // prove -> apply -> (consume) -> state advances

// Core (offline): encodings, commitment, calldata builders, proof pre-check.
export * from "./encoding.ts";
// The app-author boundary: typed Logic<State, Action>.
export * from "./logic.ts";
// The pluggable execution seam.
export * from "./backend.ts";
// The high-level lifecycle handle + deploy/attach.
export * from "./shard.ts";

// Reference backend (strkd wallet companion) + its raw client.
export { StrkdBackend, type BoundsPolicy } from "./strkd-backend.ts";
export { Strkd, SN_SEPOLIA, type ResourceBounds } from "./strkd.ts";

// Encrypted-state DA — STARK-curve ECIES matching src/crypto_kit.cairo (in-circuit da_kit).
export * from "./da.ts";
// Reference apps.
export * from "./apps/counter.ts";
export * from "./apps/committee.ts";
export * from "./apps/lending.ts";
export * from "./apps/register.ts";
