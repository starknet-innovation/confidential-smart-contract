# Contributing

Questions about the design and fixes to the Cairo framework or example logics are welcome.

## Before you start

Read `README.md` for the map of the repository and `DESIGN.md` for why the system is built this
way. `docs/project/PROCESS.md` explains how work is tracked and handed off.

## Changing the Cairo package

1. Install the tool versions listed in `.tool-versions` (Scarb and Starknet Foundry). Both
   [asdf](https://asdf-vm.com) and the official installers can read that file.
2. Open an issue describing the behaviour you want and how it should be tested.
3. Create a branch. Add or change a test under `tests/unit/` or `tests/acceptance/`, then change
   `src/`. Declare any new test file in `tests/lib.cairo`, or it will not run.
4. Run the gates:

   ```sh
   scarb fmt --check
   scarb lint --test --deny-warnings
   scarb build
   snforge test
   ```

5. Open a pull request. CI runs the same four commands. A code owner reviews before merge.

A change to the frozen framework's interface, events, storage or commitment scheme must update
`DESIGN.md` in the same pull request.

## Changing the orchestration client

`orchestration/` is outside the gates above and is not built by CI. Say in the pull request how
you tested a change there.

## Optional pre-commit hook

Maintainers use a pre-commit hook that checks the staged files with a shared tooling checkout.
It is opt-in and needs that checkout, located through `ENGINEERING_PRACTICES_ROOT`:

```sh
git config core.hooksPath .githooks
```

Without the checkout, run the four commands above by hand. CI is the authority either way.

## Security

Please do not open a public issue for a vulnerability. Contact a code owner privately first.

See `AGENTS.md` for the full working agreement, which also applies to coding agents.
