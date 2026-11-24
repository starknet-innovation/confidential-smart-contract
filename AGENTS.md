# Agent instructions

Read [README.md](README.md) for project context and conventions.

Use the repository's existing manifests, scripts, and CI workflows to choose
build and validation commands for the files you change.

## Claude Code and Codex

These instructions apply to both agents. `CLAUDE.md` imports this file. Before
editing a directory, read its scoped `AGENTS.md` when present. Shared local skills
are discoverable under `.agents/skills`; `.claude/skills` provides compatibility.
Use the host's native tools for questions, planning, and delegation when a workflow
mentions a Claude tool name. Preserve the workflow's permission and review gates.
If a required capability is unavailable, report it instead of claiming it ran.

## Hygiene level: Tier 1 baseline (Cairo package only)

The Cairo package at the repository root (`Scarb.toml`, `src/`, `tests/`) holds a Tier 1
baseline: pinned tools, a committed lockfile, tests kept apart from source, fatal warnings, and
the same gates locally and in CI. It claims nothing beyond that. `orchestration/` (the TypeScript
client) is **not covered**: it has no pinned gate here and CI does not build or test it.

Tool versions are pinned in `.tool-versions`. A missing or different tool is a failure, not a
reason to skip a step. All four gates must pass before a change is handed over:

```sh
./scripts/check.sh   # scarb fmt --check, lint with warnings denied, build, snforge test
```

Compiler warnings are errors (`allow-warnings = false` in `Scarb.toml`). Never relax a gate,
delete a test or loosen an assertion to get a green result. If a gate is wrong, change it in its
own reviewed commit.

Layout rules:

- `src/` holds production Cairo and the mock contracts the tests deploy. No `#[test]` or
  `#[cfg(test)]` code lives there.
- `tests/unit/` exercises library helpers directly; `tests/acceptance/` drives deployed contracts
  through their public interfaces. Add `integration/`, `fixtures/` or `support/` when needed.
  Nothing else sits directly under `tests/`.
- `tests/lib.cairo` only declares the suites. snforge silently ignores a nested suite that is not
  declared there, so add the `mod` line whenever you add a file.
- Keep one current implementation. Earlier versions belong in Git history, not in `v1`/`old` trees.

How to work:

1. Follow `docs/project/PROCESS.md`: claim the item in `STATUS.md`, log the session in `LOG.md`.
2. Write or change the test first, then the contract. Keep each branch to one small change and
   open a pull request; do not push to `main`.
3. `ConfidentialShard` is the frozen framework. A change to its interface, events, storage or
   commitment scheme is a design change: update `DESIGN.md` in the same pull request.
4. In the handover, list the commands you actually ran and their results, and anything you could
   not run. Do not report a check as passed if it did not run.

Never commit secrets, private keys, account files or a filled-in `.env`.
