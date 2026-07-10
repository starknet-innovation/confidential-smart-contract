# Project Status

> Current-state snapshot: what's done, in flight, next, risks. Keep current — see
> [`PROCESS.md`](./PROCESS.md). History is in [`LOG.md`](./LOG.md).

**Last updated:** 2026-07-10
**Phase:** **Framework v5 + component refactor + reusable kits (2026-07-10).** The framework's
guts are a `#[starknet::component]` `ShardComponent`; `ConfidentialShard` is a thin frozen
embedder (upgradeability = opt-in fork, never the blessed contract). **v5 removed the framework
salt** (commitment = `poseidon(logic, app_state)`), which is what makes the escape hatch
MALICIOUS-operator-safe (the operator no longer holds a secret blinding). Reusable importable
modules: `salt_kit` (deterministic blinding), `crypto_kit` (STARK-curve ECIES), `da_kit`
(in-circuit encrypted DA) + SDK `da.ts`. Lending → **v3** (salt_kit). New **da_kit example**
`PrivateRegisterLogic` (blind-party encrypted DA). counter is the transparent opt-out example.
**Deep audit done (2026-07-10):** framework/kits/crypto-core CLEAN; all 7 findings were in the
lending example — the 5 exploitable/design ones are **fixed** (signer-scoped collateral, repay-
wins-over-expiry, zero-price guard, lender `cancel`), 2 noted (inbox-spam DoS, stranded
intent-fee). **53 snforge tests + typecheck green.** Earlier: committee outbox demo + lending loan
cycle ran end-to-end on Sepolia (v4, historical). Purpose: **showcase** (see DESIGN preamble).
**One-line state:** v5 stack builds + 53 tests green off-chain (framework component, salt removed, salt_kit/crypto_kit/da_kit modules, lending v3 audit-fixed, PrivateRegister da_kit example). New v5 class hashes (cairo.md; LendingLogic `0x5c6b4697…`). Pre-v5 Sepolia deployments (counter `0x6bb61654…`, committee `0x34132247…`, lending run) are historical on the v4 framework. No open blockers; a Sepolia demo on the v5 stack + re-audit of the refactor/crypto are the natural next steps.

---

## Done ✅

- [x] Architecture designed and settled — see [`../../DESIGN.md`](../../DESIGN.md).
- [x] **v1 monolithic `ConfidentialCounter`** — verified end-to-end on Sepolia (declare → deploy → prove → apply_transition → CAS). Confirmed the SNIP-36 unknowns against a real proof.
- [x] Deep security audit of v1 — 0 Critical/High/Medium; both findings later fixed (see below).
- [x] **v2 generic framework** (`ConfidentialShard`) — frozen dispatcher + logic-agnostic verifier; confidential `logic_class_hash` in the committed state; `library_call` to the committed logic; self-governing upgrades + immutability ratchet.
- [x] Reference logic: `CounterLogic` — an **immutable** dummy, checked `u128`; ships no upgrade path.
- [x] **TypeScript SDK** (`orchestration/src/`, `confidential-shard-sdk` 0.3.0): typed generic `Logic<State,Action>` (`logic.ts`) as the app-author boundary; `Shard<S,A>` lifecycle handle (`shard.ts`: `deployShard`/`attachShard`/`genesisOf`, one `.transition(action)` runs prove→pre-check→apply→consume + advances typed state, plus `deposit`/`registerIntent`); **pluggable `ShardBackend`** (`backend.ts`) with `StrkdBackend` reference impl (`strkd-backend.ts`, owns nonce/ref-block/manual-bounds); pure `encoding.ts` core (byte-identical to Cairo); `apps/counter.ts` + `apps/committee.ts` references; `index.ts` barrel. Runs under `node --experimental-strip-types` (no build step). Typecheck clean; pure-core smoke test passes. **Validated on-chain (2026-07-06):** drove the committee outbox demo end-to-end via `attachShard` + `Shard.transition`. Fixed a read-RPC race (`confirmRoot` now polls the post-apply root instead of a single immediate read).
- [x] **Cairo authoring kit** (`src/logic_kit.cairo` + `src/logics/template_logic.cairo`) — pure helpers (`build_call`, `erc20_transfer_call`, `unseen_inbox` proven-read) + a commented `ILogic` skeleton to copy. Not part of the frozen framework; covered by `tests/logic_kit.cairo`.
- [x] **v3 public interaction (outbox)** — transitions **read public state** (proven against the SNIP-36 reference block) and emit **public calls**: `apply_transition` records `poseidon(Serde(actions))` to the outbox; permissionless one-shot `consume` re-supplies + hash-checks + dispatches. Root advances regardless of settlement. See [`../../DESIGN.md`](../../DESIGN.md) "Public interaction (v3)".
- [x] **Fixed both audit findings** — #1 salt reuse (per-transition rotation), #2 ungated reference upgrade (`CounterLogic` made immutable).
- [x] **Deep re-audit of the framework (v2, pre-v3)** — 0 Critical/High. Confirmed: `library_call` can't spoof `from_address`, sole-emitter holds, logic is commitment-pinned, framework is frozen.
- [x] **2026-07-03 first-principles design review** — docs corrected (false tight-accounting claim removed; risk register refreshed for v3 stakes); pre-freeze inventory identified and then decided with the user (see LOG).
- [x] **v4 public → shard (inbox) + pre-freeze surface** — all four decided items landed: (a) **inbox**: `deposit(token, amount, note)` (framework-executed `transfer_from` → trustless attribution) + `register_intent(payload)` (≤ 64 felts, optional per-shard anti-spam fee paid to the shard) + `inbox_len`/`inbox_entry` proven-read views; consumption = confidential cursor in the logic's app_state, never a framework flag. (b) **`outbox_of(key)` view** — settlement observability (honest reserved-balance accounting is now possible). (c) **freshness gate** — per-shard constructor param, default off; ⚠️ `proof_facts[4]` unverified, do not enable before the Sepolia experiment. (d) **`outputs` echoed in `Transitioned`** — the indexable (encrypted-)DA channel. Escape hatch: **decided none** (exits are logic-level). See [`../../DESIGN.md`](../../DESIGN.md) "Inbox (v4)".
- [x] **`CommitteeLogic` reference** (replaces the removed `VaultLogic`, which was an uninstructed example) — confidential M-of-N committee: threshold stark-curve approvals verified **in-proof** (shard- and nonce-bound; signatures ride in `public_input`, seen only by the prover), emits the approved arbitrary calls through the outbox. Immutable.
- [x] **`LendingLogic` reference — confidential P2P lending PoC** (`0x7602ac88…`): one shard = one loan. **min/max LTV committed-but-hidden** ⇒ liquidation price unknowable in advance. OFFERED (Alice escrows USDC) → `take` (Bob's collateral read from inbox; hidden band `minLTV ≤ draw/(coll·price) < maxLTV` enforced in-proof vs oracle; outbox pays Bob) → `close` (one method; branch forced by facts: repay ⇒ collateral→Bob + principal+interest→Alice; else price-cross OR past-due ⇒ liquidate collateral→Alice). Flat interest + duration; freshness gate ON for loan shards (stale-price defense). Uses `logic_kit`. Design (user-decided): single-operator (Charlie holds state), hide LTV only (amounts public; V2 → strk20 privacy pool), min=yield-floor/max=liquidation, collateral→lender. **Escape hatch — BUILT (v2, 2026-07-09):** every transition carries a SNIP-12 signature verified in-proof (`take`=borrower; `close`=any of operator/lender/borrower), so Alice or Bob can settle without Charlie; the successor state is echoed encrypted (hybrid ECIES to each party's key, `src/crypto.ts`) via `outputs` so any party can decrypt + self-prove (verified `commit==root`). Guards unchanged (auth only says WHO). New class `0xef3a907b…`. Sepolia escape run pending. Mocks: `MockToken` (multi-holder, `0x5d7a8f95…`), `MockOracle` (`0x1b32ae46…`). SDK app `apps/lending.ts`. **Sepolia end-to-end DONE (2026-07-08):** 3 role accounts (Alice/Bob/Charlie), mock USDC/strkBTC/oracle deployed, loan shard `0x77e51db3…` (freshness gate on); ran offer → Alice escrow 40k → Bob collateral 1 BTC → TAKE (Bob +30k at hidden 60% LTV) → Bob repay 33k → CLOSE (Alice 43k = principal + 3k interest, Bob's 1 BTC returned). LTV params never touched chain. See [[lending-poc]] / LOG.
- [x] **snforge tests — 40 passing** (lending v2 = 11: take band + below/above-LTV rejects, **escape**: borrower self-close-after-repay / lender self-liquidate-on-expiry / price-liquidate, + unauthorized-signer / bad-signature / healthy rejects, SNIP-12 cross-check) (incl. 2 audit regressions: cross-chain approval replay, deposit received-delta; + 3 `logic_kit` tests: call builders + `unseen_inbox` against a real shard): `CounterLogic` (increment/immutability/overflow) + `CommitteeLogic` (threshold approval → actions, below-threshold / duplicate-signer / non-member / stale-nonce rejects) + framework `transition` (commit determinism, `library_call` dispatch incl. committee end-to-end with real signatures, salt rotation, zero-salt reject) + `consume` (executes, double-consume/hash-mismatch/self-call rejects, `outbox_of` pending→settled) + inbox (`register_intent`/`deposit` append + read-back, payload cap, zero-deposit reject, intent fee charged, global ordering, out-of-range reject). `apply_transition`'s proof_facts path (incl. the freshness gate) is Sepolia-only, as before.

## In progress 🔄

- _(nothing currently in flight)_ — v3+v4 surface implemented, tested, and **deep-audited (2026-07-03)**.

## Open audit findings 🔎

**Framework (2026-07-02):**
1. **✅ FIXED — Medium (conf 78) constant salt reuse**: per-transition caller-supplied `new_salt` (`assert != 0`); SDK `freshSalt()`; guard + rotation tests.
2. **✅ FIXED — Low (conf 55) ungated upgrade in reference `CounterLogic`**: upgrade path removed; no reference ships one.

**v3+v4 deep audit (2026-07-03, deep mode: 5 agents incl. adversarial; 0 Critical/High; all 3 notes below the 75 confidence threshold, all resolved):**
3. **✅ FIXED — Medium (conf 70) committee approval missing chain-id** (`committee_logic.cairo`): `approval_hash` now includes `get_tx_info().chain_id`, blocking replay onto an identically-addressed shard on another network. SDK `approvalHash` mirrors it; regression test `committee_rejects_cross_chain_replay`.
4. **✅ FIXED — Medium (conf 68) `deposit` recorded nominal amount** (`framework.cairo`): now records the measured `balance_of` delta (fee-on-transfer / rebasing safe), asserts non-zero received. Needed a `balance_of` add to the framework `IERC20`. Regression test `deposit_records_actual_received_delta_not_nominal`.
5. **✅ DOCUMENTED — Low (conf 55, adversarial) `consume` ignores callee return** (`framework.cairo`): a non-reverting-`false` ERC-20 is treated as settled and the entry can't be replayed. Can't be fixed generically (opaque return ABIs); documented the revert-on-failure requirement + "don't treat `outbox_of()==0` as proof of effect" in the `consume` doc comment.

**`CommitteeLogic` SNIP-12 rewrite audit (2026-07-06, focused adversarial pass on the one changed file; 0 Critical/High):** binding (shard/nonce/chainId/calls), dedup, threshold, strict `'VALID'`, fail-closed on bad/undeployed signers, and Serde parsing all confirmed sound.
6. **✅ DOCUMENTED — Low (blind-signing)**: the SNIP-12 message carries `calls_hash`, not decoded calls, so a wallet shows a hash not the action. Off-chain mitigation (SDK derives `calls_hash` from the reviewed calls) documented in the logic comment + `committee.ts`; a production committee wanting wallet-decodable approvals should enumerate calls in the typed message.

## Next / backlog 📋

1. **✅ DONE (2026-07-06) — Outbox demo on Sepolia (`CommitteeLogic` → `consume`).** strkd shipped the `wallet_signTypedData` ↔ SNIP-12 fix (+ new key-free `companion_typedDataHash`); confirmed by hash-match and an on-chain `is_valid_signature` = `'VALID'`. Then ran m1+m2 approve → prove → apply → `consume` through the SDK: the 2-of-3 committee moved **0.05 STRK** out of shard `0x34132247…` via the outbox (nonce 0→1, root `0x5bd72f0f…`, `outbox_of` cleared to 0). First fully confidential private→public settlement on-chain. (Genesis salt recovered from the prior scratchpad; the per-transition salt rotation means a *further* transition needs a known salt or a fresh deploy.)
1b. **(done 2026-07-06) ~~Fresh Sepolia deploy + reference-age experiment~~** — completed; see Artifacts + LOG. `proof_facts[4]`=ref block number and `[5]`=block hash confirmed; a 118-block-stale reference was accepted at apply (gate off) → freshness gate is load-bearing. Inbox deposit verified.
3. **DA plan for non-toy state**: for multi-party shared state, the decided direction is **encrypted on-chain DA** (logic-level: ciphertext of the new state/diff in `outputs`, computed in-proof, hash-bound; now indexable via the `Transitioned` event). Worth packaging as a reusable Cairo component (Poseidon-keystream encrypt + append to outputs) when the first multi-party logic is built.
4. **Multi-party exit-fairness logic pattern** — the committee reference demonstrates authorization; a full multi-party pool logic would add: encrypted-DA publishing, inbox-intent servicing rules (exit requests), and reserved-balance accounting via `outbox_of`. Design pass needed before building (state-channel-grade adversarial reasoning).
5. **(If/when upgrades are wanted)** ship a *gated* upgradeable logic as a separate example — e.g. the committee's threshold machinery applied to a member-rotation / logic-upgrade directive.

## Known risks / watch-items ⚠️

- **The framework MUST stay frozen** (no `replace_class`/admin/`root` setter). Load-bearing for logic-immutability. The v4 surface landed **before** any real deploy precisely because frozen means never-addable; the surface is now considered final. (`consume` only replays proven bundles; the v4 constructor params are per-instance genesis config with no setters.)
- **Outbox is non-atomic (accepted, user decision):** the root advances even if an outbox entry never settles. Keeping the ledger honest is a **logic** choice; with v4's `outbox_of`, honest reserved-balance accounting is now *possible* (track unsettled keys in app_state, prove settlement) — but no shipped reference does balance accounting (`CommitteeLogic` is authorization-based). See [[outbox-vs-atomic-actions]].
- **DA loss = locked funds:** a shard holds real ERC-20s; losing the off-chain state (or a bricking upgrade) permanently locks them — **no escape hatch exists, by explicit decision (2026-07-03)**. Mitigation is logic-level: encrypted on-chain DA (the chain becomes the backup) — see DESIGN "Inbox (v4)".
- **Freshness gate — verified (2026-07-06):** `proof_facts[4]` IS the reference block number and `[5]` the block hash (confirmed on Sepolia). The protocol does NOT enforce a tight reference-age window (a 118-block-stale reference applied fine on a gate-off shard), so a shard that needs exit fairness MUST set `freshness_window > 0`; the gate index is correct.
- **Inbox spam:** junk entries inflate honest proving cost (logics read past them). Mitigations: per-shard intent fee (dark knob, default 0), payload cap (64), logic-level processing caps / dust thresholds.
- **Confidentiality boundary:** any public call (a `consume`d action) is public; deposits and intents are public; transition timing + message shapes fingerprint the application (see the 2026-07-03 review — behavioral fingerprinting means which-logic privacy is thin for bespoke logics). What stays confidential: state contents, decision inputs, WHO approved (committee).
- **Bricking by bad upgrade is accepted** (user decision): fail-closed stall; framework only asserts `next != 0`.
- **Phase-1 SNIP-36 trust model** (sequencer-side verification): a sequencer accepting a false proof can write a `root` whose preimage it chose, then drain shard-held funds through the outbox. Do not anchor real value under Phase 1. (Related, accepted: SNIP-36 proofs are **aspirationally ZK** — not yet witness-hiding; accepted knowingly 2026-07-03.)
- **v3+v4 surface deep-audited 2026-07-03** (0 Critical/High; 3 below-threshold notes fixed/documented — see Open audit findings). Residual: `apply_transition`'s proof_facts path (incl. freshness gate) + on-chain `consume` are network-only-testable, pending the Sepolia deploy.

## Artifacts

**Framework class hashes (current build, 2026-07-03):**

| Class | Hash |
|-------|------|
| `ConfidentialShard` | `0x54d35d6bde0f4abf8f2ca63c6647ca15c3152655913eb838da5df1e1c56997c` |
| `CounterLogic` | `0x1acb3488cfe126eb7d06bdd445bed46006768097be9791f2632912921e5feb5` |
| `CommitteeLogic` (SNIP-12/`is_valid_signature`, 2026-07-06) | `0x3e08859c716af05769f71285fce006435d863e1047696d302d78171ae8b5e6a` |

**v4 Sepolia deployment (2026-07-06):**
- Agent account (funder/submitter): `0x04078aa88fd37258ad019413af8ba35c509e701c984aaaa2c41c3834f4363906`
- `ConfidentialShard` declared: class `0x54d35d6b…` (tx `0x70e5d1a2…`); `CounterLogic` declared: `0x1acb3488…` (tx `0x2e7e66d5…`).
- **CounterLogic shard:** `0x6bb61654c22e728c5efc9ed74053e4b7caaedb5e43e08ae445b4507f2bbd36` (deploy tx `0x373cb6d5…`, UDC, gates off: freshness 0 / fee 0).
- genesis_root `0x31647b99…` (count 0) → transition 1 `0x57047366…` (count 1, apply tx `0x100076eb…`) → transition 2 `0x65bbd855…` (count 2, apply tx `0x473259cc…`, proven against 118-block-stale ref).
- Inbox deposit: 1 STRK, tx `0x3ae58401…`; `inbox_entry(0)` = DEPOSIT / caller = agent account / [STRK, 1e18, 0, note 0xc0ffee].

**Committee (SNIP-12) outbox demo (2026-07-06, COMPLETE — see backlog #1):**
- `CommitteeLogic` re-declared: class `0x3e08859c…` (tx `0x4649997a…`).
- Members: m1 = main `0x04078aa8…` (signer), m2 = `0x050fdb8f…` (index 7, deployed, signer), m3 = `0x06147515…` (index 8, counterfactual non-signer).
- 2-of-3 committee shard: `0x34132247dc05a498c301141c83c6ebb589ed727f89f4cb67396f1f416c70ada` (genesis `0x5a253eb7…`, gates off), funded 1 STRK. Demo executed: committee approved a 0.05 STRK transfer → main; after apply+consume the root is `0x5bd72f0f78071b9fb96049dab549b8f68facea79921003c7e1a846d00007205` (nonce 1) and the shard holds 0.95 STRK. consume tx `0x58fb4a8f…`.
- Confirmed proof_facts: `[0]=0x50524f4631 'PROOF1'`, `[1]='VIRTUAL_SNOS'`, `[4]`=ref block number, `[5]`=ref block hash, `[7]`=1, `[8]`=message hash.

**v1 monolithic deployment (Sepolia, historical):** contract `0x285b651f…`, class `0x7c0bbb31…`, account `0x04078aa8…` (see [`LOG.md`](./LOG.md)).
