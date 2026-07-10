# Progress Log

> Append-only, **reverse-chronological** (newest at top) diary of what happened and
> why. This is the narrative history; the current-state snapshot is
> [`STATUS.md`](./STATUS.md). See [`PROCESS.md`](./PROCESS.md) for when and how to
> add entries.

## Entry format

Copy this template to the top of the log (under this heading) for each work session:

```
## YYYY-MM-DD — <short title>

**Did:** <what was accomplished this session>
**Why / decisions:** <notable choices and their rationale>
**Blockers / surprises:** <anything that went sideways; how it was resolved or is it open>
**State after:** <where things stand; what STATUS.md now reflects>
**Next:** <the intended next step for whoever picks up>
```

Keep entries factual and dated. Convert relative dates to absolute. Link commits,
tx hashes, or [[memory]] items where useful.

---

## 2026-07-10 — Deep audit of the v5 stack + lending audit fixes

**Did:** Ran the cairo-auditor (deep, 5 agents) over the whole v5 stack, then verified + applied
fixes. **Framework, kits, and crypto-core came back CLEAN**; all 7 findings were in the lending
example. Applied 5 fixes to `src/logics/lending_logic.cairo`:
- **#1 (High) collateral front-run** — `take` summed the *first* collateral deposit regardless of
  depositor, so an attacker's dust deposit could hijack the borrower slot / brick the take. Now
  `take` verifies the signature FIRST and sums collateral **scoped to the signer's address**
  (`sum_deposits(entries, collateral_token, signer)`); removed `find_collateral`.
- **#2 (High) expired-repaid double-dip** — `close` gated repayment on `!expired`, so a fully-repaid
  loan settled after expiry would liquidate. Now **repayment wins over expiry** (`if repaid >= owed`
  first, unconditionally).
- **#5 (Medium) zero-price** — a zero oracle price collapsed the liquidation gate to always-true.
  Now both `take` and the liquidate branch `assert(price != 0)`; moved the price read into the
  liquidate branch so a repay-close needs no oracle.
- **#4 (Medium) no cancel** — a mistaken/abandoned OFFERED loan stranded the lender's escrow forever.
  Added `OP_CANCEL` + role-dispatch on OFFERED (`signer == lender → cancel`, else `take`) and
  `fn cancel` (lender-only, refunds the loan-token escrow, status→CLOSED).
Added 5 regression tests (dust front-run ignored, repaid-when-expired, lender-cancel, take/close
zero-price). Noted (not code-fixed): **#3** inbox-spam DoS (unbounded `unseen_inbox` scan — mitigated
by the per-shard intent fee; a logic-level cap is the real fix), **#7** stranded intent-fee (fees
accrue to the shard with no sweep), **#6** crypto domain-sep (adversarial agent refuted
exploitability). SDK `apps/lending.ts` gained the `cancel` action + `OP_CANCEL`.

**Why / decisions:** #1/#2/#5 are unambiguous correctness bugs; #4 is a small availability
addition the escape-hatch spirit demands (either party shouldn't be able to strand the other's
funds). #3/#7 are design notes, not V0 blockers for a showcase (the intent fee already prices
inbox spam; loan shards have no intent flow). #6 was refuted under adversarial review.

**Blockers / surprises:** the auditor's `structured_report.py` rendered 0 findings (schema mismatch
between the agents' JSON and finding.schema.json) — I merged the 9 raw agent findings by hand rather
than publish a false "all clear." One test renamed (`take_rejects_non_borrower_signer` →
`take_rejects_signer_without_collateral`, now `'no collateral'` since collateral is signer-scoped).

**State after:** `scarb build` clean; `snforge test` **53 pass** (was 48; +5 regressions); SDK loads
under the strip-only runner. New LendingLogic class hash `0x5c6b46972d9c1e7e1d063feec5d11ef3d4d8cfc697547c2f553fd1c6bcdba6d`
(cairo.md updated). docs/code/cairo.md also de-v4'd (ShardState/transition/commit no longer show salt).

**Next:** optional — Sepolia demo on the v5 stack; address #3 (logic-level inbox cap) and #7
(fee sweep) if the lending example graduates past showcase; strk20 privacy pool (V2).

## 2026-07-10 — Framework→component + v5 (salt removed) + kits + lending v3 + da_kit example

**Did:** Big re-architecture. (1) Extracted the framework's guts into a `#[starknet::component]`
`ShardComponent` (src/shard_component.cairo); `ConfidentialShard` is now a thin frozen embedder —
so an upgradeable variant can embed the same audited component (upgradeability = opt-in fork,
never the blessed contract; the user chose NOT to make the canonical framework upgradeable).
(2) **v5: removed the framework salt** — commitment is `poseidon(logic, app_state)`, `transition`
drops `new_salt`, `ShardState` drops `salt`. (3) Built reusable importable **modules**: `salt_kit`
(deterministic blinding via a `seed` in app_state), `crypto_kit` (STARK-curve ECIES: `ec_op` KEM +
Poseidon-CTR/MAC DEM), `da_kit` (`seal`/`open` over crypto_kit); SDK `da.ts`. (4) Lending → **v3**
(salt_kit seed at app_state[20]; dropped the operator cipher; 21-felt state). (5) New **da_kit
example** `PrivateRegisterLogic` — blind-party encrypted DA (`step` seals state to parties; they
`da.open` off-chain). counter stays transparent (opt-out). Removed the dead P-256 `crypto.ts`.

**Why / decisions:** The escape hatch's malicious-operator safety REQUIRED removing the framework
salt — I earlier claimed the constant-salt trick sufficed without a framework change; that was
WRONG (the operator-chosen `new_salt` is a secret only they know → they could pick an
unrecoverable one and lock parties out; salt_kit/da_kit atop the free-salt framework were only
absent-operator-safe). v5 makes `step` the sole author of every committed felt, so
blinding-in-app_state / in-circuit seal are genuinely malicious-operator-safe. Kits are MODULES
not `#[starknet::component]`s because they're stateless pure functions (like OZ's `snip12` util
this repo already imports) — component form would add ceremony + storage bloat to every logic for
zero gain. The framework IS a real component (it has storage + entrypoints).

**Blockers / surprises:** none material — a large but mechanical migration (every logic/test/SDK
file touched: commit drops salt, transition drops new_salt, committee+lending add a seed,
counter transparent). Removed the obsolete `transition_rejects_zero_new_salt` test.

**State after:** `scarb build` clean; `snforge test` **48 pass**; `npm run typecheck` clean; SDK
smokes pass (v5 encoding, escape resume). New v5 class hashes (see cairo.md / lending-poc memory);
counter's is unchanged. Pre-v5 Sepolia deployments are historical (old class hashes).

**Next:** optional — Sepolia demo on the v5 stack (a party self-settling from reconstructed state,
or a PrivateRegister resume); a focused re-audit of the component refactor + the custom crypto_kit
DEM; strk20 privacy pool (V2) for hidden amounts.

## 2026-07-09 — Lending escape hatch (v2): signature-authorized transitions + encrypted-state DA

**Did:** Built the loan-specific unilateral escape hatch the user asked for. Key realization
(verified in framework.cairo): `apply_transition` / `consume` are already PERMISSIONLESS
(security = proof↔message binding + CAS, not caller identity), so the escape is a
state-availability + authorization problem, not a framework change. LendingLogic v2
(`0xef3a907b…`) adds: (1) **signature auth** — every transition carries a SNIP-12 signature
verified in-proof via the signer's `is_valid_signature` (reuses committee's `ISRC6`/
`MemberSig`); `take` must be borrower-signed, `close` by any of {operator, lender, borrower},
so Alice/Bob can settle without Charlie. (2) **encrypted-state DA** — each transition echoes
an opaque `cipher` (successor `app_state`+`salt`, encrypted OFF-CHAIN to every party's key)
into `outputs`→the Transitioned event; a party decrypts the latest blob and self-proves,
verifying via `commit==new_root`. (3) expiry liquidation already existed; now lender-triggered.
Added `nonce` to app_state (single-use auth). SDK: `src/crypto.ts` (hybrid ECIES — P-256 ECDH
+ HKDF + AES-GCM, node webcrypto, no deps; felt-encoded), `apps/lending.ts` v2
(`loanActionTypedData`/`loanActionMessageHash`, `resumeState`). Tests: lending suite rewritten
+ escape scenarios → **40 snforge pass**; SDK smoke incl. encrypt→resume round-trip; typecheck
clean; SNIP-12 hash cross-checked (`0x65072805…`).

**Why / decisions:** the proven guards (band; repay/liquidate/expiry; 'loan healthy') stay the
outcome authority — a signature only says WHO acts, so an authorized party can never force an
unfair result. Encryption is off-chain (Cairo echoes an opaque blob); threat model is operator
*absence*, so a garbage cipher is detectable by the parties (decrypt≠root), never a fund risk —
in-circuit encryption (trustless-vs-malicious) is the heavier future option. Per-party ECIES
(not a shared key) to match "encrypted to the key of all parties." Reused the committee's
AA-native SNIP-12 machinery.

**Blockers / surprises:** none material. Cairo test gotcha: the close successor increments the
nonce, so the expected-`new_root` helper had to bump index 19. TS: `KeyUsage` isn't in scope
without the DOM lib (used a concrete string union).

**State after:** `scarb build` clean; `snforge test` 40 pass; `npm run typecheck` clean; SDK
smoke green. Escape hatch complete off-chain.

**Next:** Sepolia escape demo (deploy a v2 loan, then have BOB self-close via his own strkd
prover + signature — Charlie uninvolved; and/or Alice self-liquidate on expiry). Needs the
operator present for strkd approvals; the low-quota RPC caveat still applies.

## 2026-07-08 — Confidential lending PoC: full loan cycle LIVE on Sepolia

**Did:** Ran the confidential P2P lending PoC end-to-end on Sepolia with one account per role.
Created + funded + deployed Alice (`0x033de56d…`) and Bob (`0x0136ca09…`); used the existing
funded operator `main` as Charlie. Declared LendingLogic/MockToken/MockOracle; deployed mock
USDC (`0x32e9990e…`), strkBTC (`0x40748…`), oracle (`0x6b9fc2…`, 50k price 1e18-scaled);
minted; deployed the loan shard (`0x77e51db3…`, freshness_window=2000, hidden 50%/80% LTV).
Flow: Alice escrowed 40k USDC → Bob posted 1 BTC collateral → **TAKE** proved (hidden band
enforced in-proof vs oracle) / applied / consumed → Bob received **30k USDC at a hidden 60%
LTV** (root `0x2fa3c2d8…`) → Bob repaid 33k → **CLOSE** proved / applied / consumed →
collateral returned to Bob, **Alice 40k→43k** (+3k interest), shard emptied (root
`0x2b48c739…`). The LTV thresholds only ever appeared inside the Poseidon commitment.

**Why / decisions:** repayment (happy-path) chosen for the on-chain demo — richest path
(inbox repayment read, interest, collateral return); liquidation stays snforge-covered.
Charlie=main (already funded; a fresh Charlie would need ~40 STRK moved for the proof
bounds). Requested a 1-day strkd grant so own-account ops didn't prompt individually.

**Blockers / surprises:** strkd's configured Sepolia RPC node is **low-quota** — both
declares and PROVING repeatedly hit HTTP 429 / "rate limit exceeded" (proving fetches lots
of state). Worked around with patient backoff (declares 60–90s; a prove-level retry that
re-picks block+nonce each attempt — the close proof succeeded on the 3rd try). Real fix: a
higher-quota RPC in strkd Settings. Charlie ran low on STRK (big LendingLogic declare +
deploys ≈ −20 STRK; proof-carrying `apply` authorizes ~29 STRK max-bounds) → topped up +18.
Manager-nonce race funding two accounts back-to-back (serialize). All recorded in
[[lending-poc]] / [[sepolia-test-deployment]].

**State after:** loan shard CLOSED on Sepolia; all balances settled as expected. Cairo 36
tests still green; SDK unchanged. Second framework app proven end-to-end on-chain (after the
committee outbox demo).

**Next:** optional — on-chain liquidation path (drop the mock oracle price, close → collateral
to Alice); the escape hatch; V2 strk20 for hidden amounts.

## 2026-07-06 — Confidential P2P lending PoC (LendingLogic) — built + tested; Sepolia run pending

**Did:** Built the flagship inbox+outbox example: confidential peer-to-peer lending. Alice
lends USDC, Bob borrows against strkBTC, Charlie operates. One shard = one loan.
`src/logics/lending_logic.cairo` (OFFERED→take→close), reusing the `logic_kit`
(`unseen_inbox`, `erc20_transfer_call`). Added `MockToken` (multi-holder ERC-20, since the
existing single-holder `MockERC20` can't track multi-party flows) + `MockOracle`. 7 snforge
tests (36 total, all green): take enforces the hidden band + rejects below-min / above-max;
close repays, price-liquidates, expiry-liquidates, and rejects a healthy loan. SDK app
`orchestration/src/apps/lending.ts` (`Logic<LendingState, LendingAction>` + `offer()` +
pure `originationOk`/`owed`); typecheck + a pure smoke test pass. Class hashes computed
(LendingLogic `0x7602ac88…`, MockToken `0x5d7a8f95…`, MockOracle `0x1b32ae46…`).

**Why / decisions (all user-answered in the interview):** single-operator (Charlie holds
state; privacy vs the public chain, not vs Charlie); **hide LTV thresholds only** for v0
(amounts public; V2 → strk20 privacy pool for amounts); **min LTV = Alice's yield floor,
max LTV = liquidation threshold** — since minLTV is about yield, the draw is variable and
the band is enforced both sides; **liquidation settlement = collateral → Alice**; add
**interest (flat term) + duration**; **full Sepolia deploy/run** is the chosen depth;
**one shard per loan**; **mocks** for oracle + tokens. My mechanic calls: freshness gate ON
for loan shards (stale-price liquidation defense); liquidation is proof-enforced (Charlie
can't close a healthy, unexpired, unrepaid loan — the proof asserts false).

**Blockers / surprises:** None in the build. Two Cairo test gotchas (self-inflicted): a
`MessageToL1.to_address` is an `EthAddress` not `ContractAddress`; and app_state arrays
aren't index-assignable (rebuild to flip status). **Escape hatch (Q1):** a true unilateral
exit is hard under single-operator (only Charlie holds the salt to prove a close); the clean
path is Charlie sharing state so Alice/Bob can self-prove — deferred to a later demo.

**State after:** `scarb build` clean; `snforge test` 36 pass; `npm run typecheck` clean;
lending smoke test passes. Cairo + SDK + tests done.

**Next:** The Sepolia end-to-end (declare LendingLogic/MockToken/MockOracle → deploy mocks →
offer + escrow → Bob deposits collateral → prove/apply/consume take → repay or liquidate
close). Needs the operator present for the strkd approvals (~8–10 prompts). Then backlog:
the escape hatch, and the strk20 privacy-pool integration for hidden amounts (V2).

## 2026-07-06 — strkd fix confirmed → committee outbox demo COMPLETE on Sepolia (via the SDK)

**Did:** strkd shipped the `wallet_signTypedData` ↔ SNIP-12 fix (+ a new key-free
`companion_typedDataHash`). Confirmed it two ways: (1) `companion_typedDataHash` == our
contract/starknet.js approval hash for both members; (2) a strkd-signed approval passed the
member account's on-chain `is_valid_signature` (`'VALID'`) — the exact call that returned
`0x0` for all 16 encodings before. Then ran the committee outbox demo end-to-end, driving it
through the **new SDK** (`attachShard` + `Shard.transition`): recovered the shard's genesis
salt from the prior scratchpad (`committee-state.json`), reconstructed state (commit ==
live root ✅), collected m1+m2 SNIP-12 approvals, and proved → applied → consumed. Result:
2-of-3 committee moved **0.05 STRK** out of the shard via the outbox; nonce 0→1, root now
`0x5bd72f0f…`, `outbox_of` cleared to 0. First fully confidential private→public outbox
settlement on-chain.

**Why / decisions:** Drove it through the SDK (not ad-hoc scripts) so the run doubles as the
SDK's on-chain validation. Kept the proposal small (0.05 STRK, recipient = main) — testnet,
funds return to the operator.

**Blockers / surprises:** Hit + fixed a real SDK robustness bug: `Shard.transition`'s
post-apply root check did a single immediate `getRoot`, which raced read-RPC propagation
(strkd broadcasts via its node; we read via cartridge, which trailed) → spurious "root
mismatch" throw AFTER apply already succeeded. Fixed with `confirmRoot`, a bounded poll that
tolerates lag (throws only on a genuine divergent root or timeout). The consume then ran
fine. Also: the committee shard's per-transition salt rotates, so the nonce-1 salt is a fresh
CSPRNG value that was NOT persisted — a *further* transition on this shard would need a
known salt (deploy fresh if lost). Recorded in [[sepolia-test-deployment]].

**State after:** `scarb build` clean; `snforge test` 29 pass; `npm run typecheck` clean; SDK
smoke test passes. On-chain: committee shard at root `0x5bd72f0f…`, 0.95 STRK. The prior
session's sole open blocker (strkd typed-data hashing) is CLOSED.

**Next:** Optional — a second on-chain transition (needs a known salt / fresh deploy), or SDK
packaging polish. No open blockers.

## 2026-07-06 — SDK: typed Logic + Shard handle + pluggable backend + Cairo authoring kit

**Did:** Turned the loose `orchestration/` scripts into a real SDK so apps are easy to build.
TS side: extracted the byte-proven encodings into `src/encoding.ts`; made the app-author
boundary a first-class **generic `Logic<State, Action>`** (`src/logic.ts`, `defineLogic`) —
no more `unknown`, no more type buried in `counter.ts`; added a **pluggable `ShardBackend`
seam** (`src/backend.ts`) with `StrkdBackend` (`src/strkd-backend.ts`) as the reference impl
that owns nonce/reference-block/manual-bounds policy; added the **`Shard<S,A>` lifecycle
handle** (`src/shard.ts`) — `deployShard` / `attachShard` (resume) / `genesisOf`, and one
`shard.transition(action)` that runs prove→pre-check→apply→(consume) and advances typed
local state, plus `deposit`/`registerIntent`. `index.ts` is the public barrel; the two
references moved to `src/apps/{counter,committee}.ts`, now fully typed. `orchestrate.ts` is
a thin demo (dry-run unless `RUN_ONCHAIN=1`). Cairo side: added a **logic authoring kit** —
`src/logic_kit.cairo` (`build_call`, `erc20_transfer_call`, `unseen_inbox` proven-read
helper) and `src/logics/template_logic.cairo` (commented copy-paste `ILogic` skeleton).

**Why / decisions:** User picked "TS SDK + Cairo authoring kit" and "pluggable backend" (vs.
strkd-coupled). The backend seam is the honest SDK shape: `Shard` never knows it's driving
strkd, so a starknet.js account + self-hosted prover can drop in later by implementing five
methods. The kit is deliberately NOT in the frozen framework (no contract/storage/trust
surface) — pure helpers a logic *may* import. Renamed the npm package to
`confidential-shard-sdk` (0.3.0).

**Blockers / surprises:** None. (Reminder: `0xREC` isn't valid hex — R is not a hex digit.)

**State after:** `scarb build` clean; `snforge test` **29 passed** (26 prior + 3 new
`logic_kit` tests, incl. `unseen_inbox` against a real deployed shard); `npm run typecheck`
clean. No Cairo behaviour changed — the framework + reference logic class hashes are
unchanged, so nothing needs re-declaring. `TemplateLogic` is new but is a template, not a
deployed class. Docs updated: `docs/code/orchestration.md` (rewritten for the SDK),
`docs/code/cairo.md` (authoring kit + 29-test count).

**Next:** Optional — publish/package polish (subpath exports, a README quickstart), or add a
third reference app that exercises `unseen_inbox` + outbox together. The strkd
`wallet_signTypedData` ↔ SNIP-12 gap (committee on-chain demo) remains the only open blocker
from the prior session; unaffected by this work.

## 2026-07-06 — CommitteeLogic → AA-native SNIP-12 + is_valid_signature (unblocks outbox demo)

**Did:** Reworked the outbox reference logic so it can be driven key-safely. `CommitteeLogic`
now stores member ACCOUNT ADDRESSES (not raw pubkeys) and verifies each approval as a
**SNIP-12 typed message** via the member account's SRC-6 **`is_valid_signature`** (a proven
read against the reference block, so member addresses never touch chain). Added `ISRC6` +
`MemberSig` to the logic module; used `openzeppelin_utils` (added dep) for the SNIP-12
domain; pinned `APPROVAL_TYPE_HASH` + `DOMAIN_VERSION=1` from starknet.js and added a
**cross-check test** asserting the Cairo hash == `typedData.getMessageHash`. Added a
`MockAccount` (SRC-6) for tests; rewrote all committee tests to use member accounts +
`wallet_signTypedData`-shaped approvals. Rewrote SDK `committee.ts` (`approvalTypedData` /
`approvalMessageHash`; members sign via `wallet_signTypedData`). Focused adversarial audit of
the changed file: **0 Critical/High**; one LOW (blind-signing: the typed message carries
`calls_hash` not decoded calls) documented + mitigated (SDK derives `calls_hash` from the
reviewed calls). Docs (DESIGN, cairo.md, orchestration.md, STATUS) updated. **26 snforge
tests pass; typecheck clean.**

**Why / decisions (with the user):** the user asked whether `is_valid_signature` could
replace raw stark-curve verification (per the account-abstraction skill). It can, and it's
strictly better: AA-native (members can be any account type), key-safe (no raw-hash signing,
strkd's existing `wallet_signTypedData` suffices), and it makes the outbox demo drivable. Key
insight: `is_valid_signature` alone isn't enough — the signed message must be **SNIP-12**
typed data so the wallet can produce it; the two changes go together. Confirmed
`CommitteeLogic` is an EXAMPLE logic, not the frozen framework — so this touched one class
only: framework + `CounterLogic` hashes unchanged; no framework re-declare.

**Blockers / surprises:** starknet.js encodes a numeric-looking shortstring like the domain
version `"1"` as the felt `0x1` (not the ASCII `0x31`) — the OZ Cairo domain must use
`version = 1` (felt) to match. Caught by the cross-check test; pinned. Also: `is_valid_signature`
verifies over the exact hash passed, so the logic computes the per-member SNIP-12 hash
(folding in the signer) and the SDK/tests sign the same.

**State after:** `scarb build` clean; 26/26 tests; typecheck clean. `CommitteeLogic` re-hashed
`0x3e08859c716af05769f71285fce006435d863e1047696d302d78171ae8b5e6a` (framework `0x54d35d6b…`
+ `CounterLogic 0x1acb3488…` unchanged). Not yet re-declared on Sepolia.

**Next:** re-declare `CommitteeLogic`, create/deploy member accounts, deploy a committee shard,
fund it, then run approve → prove → apply → consume on-chain (STATUS backlog #1).

**Update (same day) — committee outbox demo staged on Sepolia, blocked at signing.** Re-declared
`CommitteeLogic` (`0x3e08859c…`), created 3 members (main + 2 new via `companion_createAgentAccount`
— note: account creation prompts even under a grant), deployed member 2, deployed a 2-of-3
committee shard `0x34132247…` (genesis matched on-chain) and funded it 1 STRK, all in a single
fund+deploy+fund multicall. Both signers approved via `wallet_signTypedData`. **Blocked:** the
committee `step` reverts `'bad signature'` — strkd's `wallet_signTypedData` signs a digest that
matches NONE of 16 SNIP-12 rev-1 encodings, including the exact `typedData.getMessageHash` value,
when tested against the member account's own on-chain `is_valid_signature` (all `0x0`). Since the
account signed the message itself, strkd's typed-data hashing must differ from the SNIP-12
standard the contract + starknet.js agree on (proven equal by the `approval_hash_matches_offchain_snip12`
test). Reported via `companion_reportIssue`. No workaround taken (signing keys locally is
disallowed; strkd exposes no raw-hash sign and no digest). Gas also spiked mid-demo (l1 ~6e14),
required a +30 STRK top-up and a reference block after the top-up (the prover balance-checks at
the reference block).

## 2026-07-06 — v4 verified on Sepolia; reference-age experiment RESOLVED

**Did:** Deployed the new v2/v3/v4 framework to Sepolia and exercised it end-to-end via the
strkd companion (re-paired existing agent account `0x04078aa8…`, 7-day grant, funded +40 STRK).
(1) Declared `ConfidentialShard` (`0x54d35d6b…`) + `CounterLogic` (`0x1acb3488…`) — the
canonical-spaced-ABI gotcha handled via `hash.formatSpaces`. (2) Deployed a CounterLogic shard
(`0x6bb61654…`) with gates off; `get_root` == off-chain genesis. (3) Two confidential
transitions applied on-chain (count 0→1→2), each with a freshly rotated salt; `get_root`
matched the off-chain `commit` each time; the v4 `Transitioned` event carried `outputs`
(`[new_root, 1, 1]`). (4) **Reference-age experiment RESOLVED:** confirmed `proof_facts[4]`
== reference block number and `[5]` == reference block hash against the real block; then proved
transition 2 against a **118-block-old** reference and it was **accepted at apply** on the
gate-off shard → the protocol does NOT enforce a tight reference-age window, so the framework
freshness gate is load-bearing (a shard needing exit fairness must set `freshness_window > 0`).
(5) v4 inbox: deposited 1 STRK (approve+deposit multicall); `inbox_entry(0)` recorded
DEPOSIT / agent-account caller / [STRK, 1e18, 0, note] — the balance-delta path (audit fix #2)
validated live. Updated the framework's `proof_facts[4]` comment, DESIGN "Reference-age
enforcement", STATUS (artifacts + risks), and this log.

**Why / decisions:** Purpose confirmed **showcase** (added the DESIGN preamble). Proved
transition 2 against a post-funding old block (high balance) rather than a 3000-block-old one:
at truly old blocks the account held only ~10 STRK and couldn't afford the v2 transition at
that block's gas price — a testnet-economics limit, not a protocol rejection. 118 blocks
(~1h) still decisively answers the enforcement question.

**Blockers / surprises:** (a) Mempool `DuplicateNonce` when firing two declares back-to-back —
waited for the first to be ACCEPTED before the second. (b) Large-class declare auto-estimate
reserves ~35 STRK (max bounds) — funded 40 STRK. (c) The prover requires the virtual tx nonce
to equal the account nonce **at the reference block**, not the current nonce. (d) **Outbox
demo (`CommitteeLogic`) BLOCKED:** it verifies raw `check_ecdsa_signature` over `approval_hash`,
but the agent may not generate keys / signature payloads (org policy) and strkd has no
raw-hash signing method (only tx-signing + SNIP-12). Filed via `companion_reportIssue` →
prefilled GitHub issue URL handed to the operator; requested a `companion_signHash` method or
a SNIP-12 approval variant.

**State after:** CounterLogic shard live at count=2; declares + shard recorded in STATUS
Artifacts. `proof_facts` layout fully confirmed. Outbox on-chain demo deferred (backlog #1).

**Next:** unblock committee signing (strkd `signHash`, or a SNIP-12 `CommitteeLogic` variant),
then demo record→`consume` on-chain.

## 2026-07-03 — Deep audit of v3+v4 + fixes; DESIGN preamble

**Did:** (1) Added the DESIGN.md purpose/trust preamble (user: **showcase**; two participation
models; the four accepted trust assumptions written down). (2) Ran `cairo-auditor` deep mode
(5 agents incl. an adversarial opus pass) over the v3+v4 surface. **Result: 0 Critical/High.**
All load-bearing invariants held under scrutiny (proof↔message binding, CAS, commit/hash_actions
preimage soundness, committee sig/dedup/threshold, sole-emitter, frozen framework). Preflight's
2 "missing access control" hits were correctly judged intended-permissionless. Three
below-threshold notes surfaced; all resolved: (3a) **committee approval chain-id** (conf 70) —
`approval_hash` now folds `get_tx_info().chain_id`, killing cross-chain replay onto an
identically-addressed shard; SDK `approvalHash` gained a `chainId` param; regression test added.
(3b) **`deposit` received-delta** (conf 68) — records the measured `balance_of` delta not the
nominal amount (fee-on-transfer/rebasing safe); added `balance_of` to the framework `IERC20`;
`MockERC20` now tracks balance + a settable fee; regression test added. (3c) **`consume`
unchecked callee return** (conf 55, adversarial) — can't be fixed generically (opaque return
ABIs), so documented the revert-on-failure requirement and the "don't treat `outbox_of()==0`
as proof of effect" caveat in the `consume` doc comment. (4) Updated docs (STATUS audit
findings + hashes, cairo.md hashes, README).

**Why / decisions (with the user):** user approved fixing 3a+3b and documenting 3c. Kept the
framework's generic dispatcher policy-free — the `consume` gap is a logic/ops assumption, not a
framework check.

**Blockers / surprises:** the `deposit` delta fix required `MockERC20` to actually move balances
(the old fixed-`bal` mock would make the new non-zero-delta assert fail) — reworked it to a
single-holder balance model with an optional transfer fee. Pinned `chain_id` in tests via
`start_cheat_chain_id_global` so the approval-hash mirror matches `get_tx_info()`.

**State after:** `scarb build` clean; **25 snforge tests pass** (added cross-chain-replay +
received-delta regressions); `npm run typecheck` clean. Class hashes changed:
`ConfidentialShard 0x54d35d6b…`, `CommitteeLogic 0x2720c374…` (`CounterLogic` unchanged).
**v3+v4 now deep-audited.**

**Next:** fresh Sepolia deploy (backlog #1) including the reference-age experiment.

## 2026-07-03 — v4 implemented: inbox + pre-freeze surface + CommitteeLogic

**Did:** Implemented the entire decided pre-freeze surface. (1) **Inbox**: `deposit(token,
amount, note)` — the framework executes `transfer_from(caller → shard)` itself, so the
appended entry is proof-of-arrival (trustless attribution) — and `register_intent(payload)`
(≤ 64 felts, optional per-shard anti-spam fee pulled to the shard), stored as an append-only
globally-ordered log with `inbox_len`/`inbox_entry` proven-read views; no consumed flags
(confidential cursor). (2) **`outbox_of(key)` view** (settlement observability). (3)
**Freshness gate**: constructor param `freshness_window` (0 = off), asserts
`current_block <= proof_facts[4] + window` in `apply_transition` — `proof_facts[4]` carries
a VERIFY marker (unconfirmed on Sepolia; do not enable until the experiment). (4) `outputs`
echoed in the `Transitioned` event (indexable DA channel). Constructor is now
`(genesis_root, freshness_window, intent_fee_token, intent_fee_amount)` — per-instance
genesis config, no setters. (5) Deleted `VaultLogic` (uninstructed example) and its
`vault.ts`; added **`CommitteeLogic`**: confidential M-of-N committee, approvals =
stark-curve signatures over `poseidon(DOMAIN, shard, nonce, Serde(calls))` verified
in-proof (shard-bound via library_call context, nonce-bound vs replay, dedup + membership
checks), threshold-gated, emits the approved arbitrary calls as outbox actions; signatures
ride in `public_input` (prover-only) so WHO approved stays confidential. (6) SDK:
`shardConstructorCalldata`/`depositCalldata`/`registerIntentCalldata`,
`examples/committee.ts` (`approvalHash`/`signApproval` mirrors), driver deploy updated.
(7) Tests rewritten: **23 passing** (committee unit + end-to-end through the framework with
real snforge stark-curve signatures; inbox append/read/cap/fee/ordering; `outbox_of`
pending→settled). (8) All docs updated (DESIGN v4 → implemented, cairo/overview/
orchestration, README, STATUS).

**Why / decisions (with the user):** all four AskUser decisions went to the recommended
option: full v4 surface (`outbox_of` + default-off freshness gate + outputs-in-event),
**no escape hatch** (exits are logic-level), **dark intent-fee knob** (default 0), and
**committee treasury replaces `VaultLogic`** (deleted). The framework surface is now
considered FINAL — it landed pre-freeze precisely because frozen means never-addable.

**Blockers / surprises:** none material — clean first compile; only a test-side type fix
(`commit` takes `Span`). `CounterLogic`'s class hash is unchanged (code untouched);
`ConfidentialShard` → `0x717fcd19…`, `CommitteeLogic` → `0xc15c0366…`.

**State after:** `scarb build` clean; 23/23 tests; `npm run typecheck` clean. v3+v4
surface **unaudited**. Sepolia deploy pending (blocked on the strkd/prover working against
current Sepolia — known blocker, user checking for an update).

**Next:** deep audit of the v3+v4 surface (STATUS backlog #1); then the Sepolia deploy
including the reference-age experiment (backlog #2). Open user input: purpose framing for
the DESIGN preamble (showcase vs product track).

## 2026-07-03 — Inbox planned (v4); DA + freshness decisions

**Did:** Designed the **inbox** (the public→shard dual of the outbox) and captured it in
DESIGN.md as a planned, pre-freeze v4 feature: framework-executed `deposit(token, amount,
note)` (trustless depositor attribution), `register_intent(payload)`, `inbox_len`/
`inbox_entry` proven-read views, confidential-cursor consumption (no framework consumed
flag), spam stance, and the exit-fairness rule for multi-party logics. Updated STATUS
backlog #2/#4.

**Why / decisions (with the user):** (1) **Encrypted-DA publishing is logic-level —
possible, not mandatory.** The framework cannot verify that a ciphertext encrypts the state
(it never sees the state; only the in-proof logic can assert it), and some shards won't want
the on-chain footprint. Trade-off documented: no DA publishing ⇒ no unilateral-exit
guarantee. Framework's only touch: echo `outputs` in the `Transitioned` event. (2)
**Freshness gate is conditional, not assumed:** SNIP-36 has a freshness bound, but
prover-side enforcement is void in our threat model (self-hosted provers) — whether the
on-chain verifier enforces reference-block age at apply time must be confirmed empirically
on Sepolia; ship a default-off per-shard gate as insurance either way. (3) Inbox approved
for planning by the user.

**State after:** design docs updated; no code changed. Open pre-freeze items: inbox
implementation, `outbox_of` view decision, escape-hatch sign-off, anti-spam-bond knob.

**Next:** implement the inbox + outputs-in-event (+ default-off freshness gate); design the
replacement outbox example (committee treasury, backlog #7); then re-audit + Sepolia deploy
including the reference-age experiment (submit a proof against a deliberately old block).

## 2026-07-03 — First-principles design review (docs corrected)

**Did:** Full review of the reasoning from the root ask (fresh agent, docs-first). Corrected
documentation to match reality: (1) removed the false "tight logic ⇒ outbox entries always
settle" claim — `VaultLogic`'s reference-block balance check cannot see earlier *unconsumed*
outbox commitments, so consecutive transitions can over-commit the same funds (DESIGN.md,
`docs/code/cairo.md`, `vault_logic.cairo` doc comment); (2) refreshed the risk register for
v3 stakes (DA loss now = permanently locked ERC-20s; Phase-1 sequencer = concrete
forge-root-then-drain path; whole-state commitment vs per-user-leaves tension named);
(3) added a **pre-freeze framework inventory** to the backlog (inbox, `outbox_of` view,
freshness gate, outputs-in-event, escape-hatch stance) — "frozen forever" means deferred
framework features are decided by omission unless settled before the first real deploy.

**Why / decisions (with the user):** ZK-ness of SNIP-36 proofs is **aspirational** — proofs
are not yet witness-hiding; user accepts this knowingly. `VaultLogic`'s framing was an
uninstructed addition ("hallucination") — the intended v3 demonstration is the **outbox**
(private contract emitting commands that trigger public contracts); a better example is
wanted (backlog #7). Target participation models clarified: single-operator AND multi-party
shared private state (private vs outsiders, not between players) with **unilateral exit** —
design direction proposed (in-logic player signatures + encrypted on-chain DA via `outputs`
+ intent inbox + freshness gate), pending user decision.

**Blockers / surprises:** none — documentation-only session; no code behavior changed
(one doc comment in `vault_logic.cairo`; class hashes unaffected by comments? **not
re-verified** — re-run `scarb build` before relying on the recorded hashes).

**State after:** docs consistent with the code and with the accepted risks. v3 audit +
Sepolia deploy still pending, and the deploy is now explicitly **blocked on the pre-freeze
inventory decision** (STATUS backlog #2).

**Next:** user decides on the multi-party / pre-freeze proposal; then the DESIGN.md preamble
(purpose, participation models, trust assumptions), the replacement outbox example, re-audit,
deploy.

## 2026-07-02 — v3: public interaction (outbox + reactive reads)

**Did:** Enabled a confidential shard to interact with the public chain. (1) `ILogic::step`
now returns a 4th value `actions: Array<PublicCall>` and MAY read public state (it's proven
against the SNIP-36 reference block). (2) `PublicMessage` carries `actions` (proof-bound via
the message hash — no new verification primitive). (3) `apply_transition` **records** the
action bundle to an on-chain outbox (`outbox[new_root] = poseidon(Serde(actions))`) instead
of executing it. (4) New permissionless one-shot `consume(new_root, actions)` re-supplies +
hash-checks + dispatches the calls via `call_contract_syscall` (CEI clear-before-call,
self-call guard). (5) `CounterLogic` returns empty actions; added `VaultLogic` (reactive
balance read + reserved-balance discipline + ERC-20 transfer action) and a test-only
`MockERC20`. (6) SDK: `PublicCall`, `serializeActions`/`hashActions`, actions in
serialize/decode, `consumeCalldata`, driver now does prove → apply → consume; added
`examples/vault.ts`. (7) Docs (DESIGN "Public interaction (v3)", all `docs/code/`, STATUS).

**Why / decisions (with the user):** Chose an **outbox** over inline-atomic execution
(user's call), mirroring Starknet's L2→L1 message outbox — the root advances regardless of
whether the external effect settles, gas at apply is bounded, and settlement can be retried
without re-proving. Accepted the cost: **no cross-domain atomicity**, so the confidential
ledger can diverge from reality. Kept the framework **lean and policy-free**: tight
reserved-balance vs relaxed unbacked payouts, and any tighter-than-protocol freshness, are
the *logic's* choice, not the framework's. Correction logged: reactive reads are already
supported by SNIP-36 (proven reference-block reads); the only real work was relaxing our
self-imposed pure-logic rule. Deposits (public → shard) explicitly deferred.

**Blockers / surprises:** `apply_transition`'s proof_facts path is Sepolia-only, so `consume`
can't be reached through it in snforge — seeded the outbox directly with `store` +
`map_entry_address(selector!("outbox"), …)` to test `consume` end-to-end (executes the
transfer against `MockERC20`; rejects double-consume / hash-mismatch / self-call). `MockERC20`
isn't `cfg(test)`-gated, so it ships in the build (accepted; excluded from audit via `mocks/`).

**State after:** `scarb build` clean; **12 snforge tests pass**; orchestration typecheck clean.
Class hashes changed (signature/storage changes): `ConfidentialShard 0xdcf6ba57…`,
`CounterLogic 0x1acb3488…`, `VaultLogic 0x5a8ff6cd…`. **The v3 surface is NOT yet audited.**

**Next:** deep re-audit of the v3 surface (outbox/`consume`/reactive reads/non-atomicity);
then a fresh Sepolia deploy demoing salt rotation + the outbox (record → consume).

## 2026-07-02 — Fix audit finding #2 (ungated reference upgrade)

**Did:** Removed the upgrade path from the reference counter — `CounterLogic` is now an
immutable dummy (`step` always returns its own class hash and ignores any extra
`public_input`). Deleted the now-redundant `ImmutableCounterLogic`. Updated the SDK counter
example (`buildPublicInput` = `[step]`, `nextState` keeps the logic hash; dropped `upgradeTo`)
and the tests.

**Why / decisions (with the user):** The user chose to make the reference counter immutable
rather than ship a gated upgradeable variant. No reference logic ships an ungated upgrade
path, so the permissive pattern can't propagate by copy-paste. The framework still SUPPORTS
upgrades (a production logic returns a different, self-gated successor from `step`) — it's
just not demonstrated by a reference.

**State after:** `scarb build` clean; **6 snforge tests pass** (logic immutability + framework
immutability-through-the-framework + salt rotation + zero-salt guard); typecheck clean.
Classes now `ConfidentialShard 0x57e64f78…` and `CounterLogic 0x4c5c6dcb…` (changed;
`ImmutableCounterLogic` removed). **Both audit findings now fixed.**

**Next:** fresh Sepolia deploy demoing salt rotation; optionally a gated upgradeable logic
example if upgrades are ever wanted.

## 2026-07-02 — Fix audit finding #1 (constant salt reuse)

**Did:** Implemented per-transition salt rotation. `transition` now takes a caller-supplied
`new_salt: felt252` and commits the successor state under it (`assert new_salt != 0`); the
current salt still binds `old_root`. So every root uses an independent, fresh, high-entropy
salt — recovering one no longer cascades across the shard's history. Salt stays a
framework-level concern; the logic never sees it. Updated the SDK (`framework.ts`:
`transitionCalldata(…, newSalt)` + `freshSalt()` CSPRNG helper; `examples/counter.ts`:
`nextState` mirror; `orchestrate.ts`: fresh salt per transition + real `new_root` pre-check).

**Why / decisions:** Chose caller-supplied fresh randomness over deterministic salt chaining
(`salt_next = poseidon(salt,…)`) — chaining still cascades from a single recovered salt,
whereas independent per-transition salts fully close the finding.

**State after:** `scarb build` clean; **7 snforge tests pass** (added
`transition_rejects_zero_new_salt` + rotation assertions); orchestration typecheck clean.
Framework class hash changed → `0x57e64f78…` (signature change; logics unchanged). Docs +
STATUS updated; finding #1 marked FIXED.

**Next:** finding #2 (gated reference logic / mark `CounterLogic` non-production); fresh
Sepolia deploy demoing upgrade + ratchet + salt rotation.

## 2026-07-02 — Generic orchestration SDK, snforge tests, fresh audit

**Did:** (1) Rewrote orchestration as a generic, logic-agnostic SDK — `framework.ts`
(commit/calldata/message encodings mirroring the Cairo), `strkd.ts` (companion client),
`rpc.ts` (read helpers), `examples/counter.ts` (the counter as one `Example`),
`orchestrate.ts` (generic driver parameterized by an Example). Removed the v1 `.mjs`
scripts; `npm run typecheck` clean. (2) Added snforge tests — **6 passing**: logic `step`
(increment, u128-overflow revert, upgrade directive, immutability ratchet) + framework
`transition` (recomputes `commit`, asserts the emitted L2->L1 message, incl. upgrade
committing the new logic hash). (3) Ran a fresh deep `cairo-auditor` on the framework + logics.

**Audit result (Execution Integrity: FULL):** 0 Critical/High. **1 Medium (conf 78)** —
constant `salt` reuse: a shard uses one salt for life, so recovering it (feasible only
under low-entropy salt) cascades to its whole history; fix = rotate salt / require high
entropy. **1 Low (conf 55)** — reference `CounterLogic`'s upgrade path is ungated
(successor from `public_input`, no in-logic authorization): fine for a single-custodian
shard (the chosen self-governance), a hijack primitive for shared state; fix = mark the
reference non-production / ship a gated variant. All other candidates (message forgery,
run-a-different-logic, storage corruption, hidden `replace_class`, ratchet bypass,
cross-shard replay, determinism) dropped as false-positive — **core design confirmed sound**.

**Blockers/surprises:** `MessageToL1.to_address` is `EthAddress` (test fix); `res.json()`
is typed `unknown` (SDK cast). `apply_transition`'s proof_facts path isn't snforge-testable
(no proof_facts cheatcode) — covered by the v1 Sepolia run + the SDK `checkProof` mirror.

**State after:** Framework compiles, 6 tests pass, audited (findings unfixed). Orchestration
generic. Not deployed.

**Next:** salt rotation (finding #1); gated reference logic / mark `CounterLogic`
non-production (finding #2); fresh Sepolia deploy demoing an upgrade + the ratchet.

## 2026-07-02 — Generic framework refactor (v2: ConfidentialShard + pluggable logic)

**Did:** Refactored the monolithic `ConfidentialCounter` into a frozen, logic-agnostic
framework (`ConfidentialShard`) plus pluggable logic classes. The confidential state
now carries `logic_class_hash`; the virtual `transition` `library_call`s the committed
logic's `step`; the on-chain `apply_transition` is unchanged (proof-binding + CAS) and
never sees the class hash. Added `CounterLogic` (upgradeable, checked `u128`) and
`ImmutableCounterLogic` (ratchet). Removed `contract.cairo`. Compiles (3 classes).

**Why / decisions (with the user):** Design "B" (library_call to a class hash), but the
class hash lives *inside the confidential commitment* rather than on-chain — so which
logic governs a shard is confidential and self-enforcing (CAS pins `old_root`, which
pins the class hash). Upgrades are self-governed by the logic (option a): `step` returns
its successor; a logic that always returns its own hash is permanently immutable (a
one-way ratchet). Bricking-by-bad-upgrade explicitly accepted. The framework must stay
frozen (no `replace_class`/admin/`root` setter) — load-bearing for the immutability guarantee.

**Blockers / surprises:** The library dispatcher shares `ILogicDispatcherTrait` (there is
no `ILogicLibraryDispatcherTrait`) — one import fix.

**State after:** Framework compiles; class hashes recorded in [`STATUS.md`](./STATUS.md).
Audit finding #1 (unbounded arithmetic) addressed in the reference logics via checked
`u128`; finding #2 (app-logic binding) is now handled by the commitment. Orchestration
still targets v1 and needs rewriting.

**Next:** Rewrite orchestration for the framework schema; fresh Sepolia deploy demoing a
logic upgrade + the immutability ratchet; snforge tests; re-audit the framework.

## 2026-07-02 — End-to-end SNIP-36 test on Sepolia

**Did:** Ran the full flow on Sepolia via the `strkd` wallet companion — created &
funded a test account, declared class `0x7c0bbb31…`, deployed
`ConfidentialCounter(genesis_root)` at `0x285b651f…`, proved the virtual
`transition` off-chain, and broadcast the proof-carrying `apply_transition`
(tx `0x21f86b1b…`). `get_root()` advanced genesis `0x5f345327…` → `0x976c9f3d…`.

**Why / decisions:** Concrete example state = minimal counter; anchor = plain
Poseidon commitment (DESIGN.md defaults). Added an off-chain pre-check
(`check_proof.mjs`) comparing `proof_facts[8]` to the recomputed message hash
*before* broadcasting, to avoid a reverting on-chain tx.

**Blockers / surprises:**
- Declare `Account: invalid signature` — turned out to be **our** bug (compact ABI
  string → node derives a different class hash). Fixed by sending the canonical
  spaced ABI. Verified this before concluding, so *no false bug report was filed*.
- Virtual-tx `resource_bounds`: over-generous (balance check) then `l1_gas: 0` too
  low (needs ~29 524). Tuned to fit.
- strkd prover initially rejected Starknet v0.14.3 — a real external blocker,
  reported to the user; resolved by a strkd update. Also needed a prover testnet
  RPC set in strkd Settings.

**State after:** All SNIP-36 `VERIFY` unknowns confirmed against a real proof;
contract comments + README updated to "verified on Sepolia." STATUS.md reflects
"verified, pending tests + audit."

**Next:** snforge unit/fuzz tests, then a `cairo-auditor` pass.

## 2026-07-01 — Scaffold written

**Did:** Wrote the Cairo pair (`transition` + `apply_transition`), shared types,
genesis constructor; and the orchestration scripts. Confirmed `scarb build` passes
and that `get_execution_info_v3_syscall` / `proof_facts` exist in corelib 2.18.

**Why / decisions:** Bound the unconfirmed SNIP-36 details (`proof_facts` indices,
message-hash formula, `to_address`) as named `VERIFY`-marked constants so there was
one place to fix each. Verified SNIP-36 details against the reference impl first;
found its examples recompute results on-chain rather than reading `proof_facts`,
leaving those specifics unverified until the Sepolia run.

**State after:** Compiles; unverified on live network.
**Next:** Run it against Sepolia to confirm the `VERIFY` items.

## (pre-2026-07-01) — Design settled

**Did:** Architecture designed and captured in [`../../DESIGN.md`](../../DESIGN.md):
off-chain state, single Poseidon anchor, SNIP-36 virtual proving, on-chain
verify + compare-and-swap. **State after:** design settled, no code. **Next:** scaffold.
