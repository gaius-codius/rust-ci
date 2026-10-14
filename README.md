# rust-ci

Shared quality setup for gaius-codius Rust projects: one reusable CI workflow, baseline config files with a drift check, and shared git hooks. Projects pin a release by commit SHA and keep their own project-only jobs. The Cargo workspace must be at the repository root.

| Piece | Where | How a project uses it |
|---|---|---|
| Reusable workflow | `.github/workflows/rust.yml` | Called from the project's `ci.yml` |
| Baseline drift check | `actions/baseline-drift` | Run by the workflow's `lint` job; warns, never fails |
| Formatting, toolchain, test profiles | `baseline/rustfmt.toml`, `baseline/rust-toolchain.toml`, `baseline/.config/nextest.toml` | Copied to the project as they are |
| Lints | `baseline/workspace-lints.toml` | Its `[workspace.lints]` tables copied into the root `Cargo.toml`; a project may add lints |
| Dependency policy, spelling | `baseline/deny.toml`, `baseline/typos.toml` | Copied as the start of the project's own file; a project adds bans, exceptions, excludes and words |
| Git hooks | `lefthook/rust.yml` | Loaded through lefthook `remotes:`, pinned to a tag |
| Claude Code hooks | `agent/claude-rust-*.sh` | Symlinked into `~/.claude/hooks/` and registered in `~/.claude/settings.json` (user-level, once per machine) |
| What moved where | `docs/inventory.md` | Every job, step and hook of nota and conspector, marked shared or project-only |

## What the workflow checks

Four jobs, on the runner the caller names. Called from a job with id `rust`, they report as `rust / lint`, `rust / test`, `rust / deps` and `rust / workflows`.

| Job | Steps |
|---|---|
| `lint` | Drift from this baseline (warnings only); the toolchain from `rust-toolchain.toml`; the setup scripts; `cargo fmt --all --check`; `cargo clippy --workspace --all-targets --locked`; `cargo doc --no-deps --document-private-items --workspace --locked` with `RUSTDOCFLAGS=-D warnings`; typos |
| `test` | The toolchain; the setup scripts; the project's pre-test action and script; `cargo nextest run` with the `test-command` arguments; the post-test script; `cargo test --workspace --locked --doc` |
| `deps` | `cargo deny check` (`--all-features --locked`); `cargo shear` |
| `workflows` | actionlint 1.7.12 (pinned by digest); zizmor 1.30.1 |
| `rules` | X2, coming: the weakened-checks detector, once it replaces the projects' `scripts/check-weakened.sh`. Not wired yet |

Every job sets `CARGO_BUILD_WARNINGS=deny`, so warnings fail clippy, the docs and the tests. The `lint` and `test` jobs cache the build with Swatinem/rust-cache.

Inputs:

| Input | Default | Meaning |
|---|---|---|
| `runs-on` | `'["ubuntu-latest"]'` | Runner labels as a JSON list |
| `timeout-minutes` | `60` | Timeout of each job (GitHub's default is 6 hours) |
| `setup-scripts` | `""` | Scripts the `lint` and `test` jobs run before building, one per line, each a path with optional arguments: native build dependencies, pinned libraries |
| `cache-key-files` | `""` | A glob of files hashed into the build cache's key, for example a script that pins a native library |
| `pre-test-action` | `false` | Run the project's composite action at `.github/actions/pre-test` before the tests. For setup that needs other actions (a cache) or sets variables for the tests (written to `$GITHUB_ENV`) |
| `pre-test-script` | `""` | A script run before the tests |
| `test-command` | `cargo nextest run --workspace --locked --profile ci --no-tests=pass` | The test run, written out in full so the project's own checks can read its arguments in `ci.yml`. Must start with `cargo nextest run`; the arguments are split on spaces |
| `post-test-script` | `""` | A script run after the tests, for checks that reuse the test build |
| `doctest` | `true` | Run doctests. Turn off while the workspace has no library crate (`cargo test --doc` fails without one) |
| `doc-all-features` | `false` | Build the docs with `--all-features` |
| `deny-arguments` | `--all-features --locked` | Arguments to `cargo deny check` |

The drift check compares the project's copies with this release's `baseline/`:

- `rustfmt.toml` and `rust-toolchain.toml` must hold exactly the baseline's settings.
- `.config/nextest.toml`, `deny.toml`, `typos.toml` and the `[workspace.lints]` tables in `Cargo.toml` must hold every baseline setting with the baseline's value; a list must hold at least the baseline's items. A project's own additions are not drift.
- Comments and formatting are not compared.

Each difference is a warning annotation on the `lint` job. The check never fails the job.

## Adopting it

Run these from the project's root.

1. **Baseline files.**

   ```sh
   RUSTCI=/path/to/rust-ci   # a clone of this repo at the tag you pin
   cp "$RUSTCI/baseline/rustfmt.toml" "$RUSTCI/baseline/rust-toolchain.toml" .
   mkdir -p .config && cp "$RUSTCI/baseline/.config/nextest.toml" .config/
   ```

   Copy the two tables in `baseline/workspace-lints.toml` into the root `Cargo.toml`, and start `deny.toml` and `typos.toml` from the baseline's, adding the project's own bans, licence exceptions, excludes and words. Keep `rust-version` in `Cargo.toml` equal to the toolchain.

2. **CI.** Replace the project's lint, test, deps and workflow-lint jobs in `.github/workflows/ci.yml`:

   ```yaml
   permissions:
     contents: read

   jobs:
     rust:
       uses: gaius-codius/rust-ci/.github/workflows/rust.yml@<release commit SHA> # v1.x.y
       with:
         setup-scripts: |
           scripts/install-linux-build-deps.sh
   ```

   Pin the full commit SHA of a release tag (`git ls-remote --tags https://github.com/gaius-codius/rust-ci 'v1.*'`), as for any third-party action: the workflow runs with your checkout. The workflow calls its own drift action with GitHub's self-repository syntax (`uses: $/...`), so the action and baseline always come from the commit you pinned.

   Project-only jobs (fuzzing, mutation testing, extra platforms, coverage, release builds) stay in the project's `ci.yml` and can `needs: rust`. Steps a project needs inside the shared jobs go in through the inputs: `setup-scripts` for packages and pinned libraries, `pre-test-action` or `pre-test-script` for test data and environment, `post-test-script` for checks that reuse the test build.

   The checks are then named `rust / lint`, `rust / test`, `rust / deps` and `rust / workflows`. Update the branch ruleset's required checks once the new names have run green once, or nothing can merge: either the old names never report, or the new ones are not yet known.

3. **Runner.** Public projects use GitHub-hosted runners (the default, `["ubuntu-latest"]`), which are free for them. Never run a self-hosted runner for a public repository: a fork's pull request could run code on the host. A private project can pass its self-hosted labels in `runs-on`.

4. **Git hooks.** Add the shared hooks to the project's `lefthook.yml`, and delete the project's own commands of the same names (`fmt`, `typos`, `workflows`, `deny`, `shear`):

   ```yaml
   remotes:
     - git_url: https://github.com/gaius-codius/rust-ci
       ref: v1.x.y   # the release your ci.yml pins
       configs:
         - lefthook/rust.yml
   ```

   then `lefthook install`. A remote's command overrides the project's command of the same name, so a project that needs a different form (other arguments, a wrapper) keeps it under another name. `ref` must be a tag or branch (lefthook can't fetch a commit SHA), and it moves with the CI pin. If lefthook can't fetch the remote (offline, a tag that doesn't exist yet) it says "Couldn't sync" and carries on without these hooks, so check that `lefthook dump` lists them.

## Claude Code hooks

Three user-level hooks for Claude Code agents, needing `jq` and, for the cargo ones, `cargo`. They share one rule: an outcome of exit 2 means "the check ran and found problems". A tool failure (a missing binary, a failed dependency fetch, a crashed tool, a held cargo build lock) never blocks; it goes out as `additionalContext` saying what could not run. Nothing is skipped silently. Tests (fake hook input, fake `cargo` and `rustfmt`, so no Rust build): `tests/test-fmt-hook.sh`, `tests/test-check-hook.sh`, `tests/test-stop-hook.sh`.

| Hook | Event | What it does |
|---|---|---|
| `agent/claude-rust-fmt-on-edit.sh` | `PostToolUse`, `Edit\|Write\|MultiEdit` | After a `.rs` edit: `rustfmt --edition <E> <file>`, with the edition from `edition` in the package's `Cargo.toml` or `[workspace.package]` (the baseline `rustfmt.toml` sets only `style_edition`, so a bare `rustfmt` would parse as edition 2015). A file that doesn't parse is exit 2 with rustfmt's message; a missing rustfmt is a tool failure |
| `agent/claude-rust-check-on-edit.sh` | `PostToolUse`, `Edit\|Write\|MultiEdit` | After a `.rs` edit: `cargo check --workspace --message-format=json`. Errors are reported wherever they are (an edit can break callers in crates it never touched); warnings only for the edited file. Doesn't wait for a held build lock |
| `agent/claude-rust-stop.sh` | `Stop` and `SubagentStop` | `cargo clippy --workspace --all-targets --message-format=json` when Rust files changed against the merge-base with `origin/main` (committed, staged, unstaged or untracked; nothing changed is silent). Every error is reported wherever it is; warnings only in changed files, so the backlog doesn't nag. Clippy's suggested replacements are shown, never applied. Findings block the stop (exit 2) |

The Stop hook can't loop. When `stop_hook_active` is true and the findings equal the last blocking set (a hash of the checked tree plus a hash of the diagnostics, kept in `rust-ci-stop-hook/` under the git dir), it exits 0 and reports them through `additionalContext` instead of blocking. On `Stop`, `additionalContext` makes Claude continue the turn, so each distinct non-blocking report (that one, a tool failure, a held lock) is delivered that way once; an identical repeat goes out only as `systemMessage`, which shows to you and doesn't continue the turn. If the agent is running cargo itself and holds the build lock, the hook reports that instead of waiting.

Stop doesn't run when you interrupt Claude, so CI remains the gate.

Install once per machine, from a clone of this repo:

```sh
mkdir -p ~/.claude/hooks
ln -sf "$RUSTCI/agent/claude-rust-fmt-on-edit.sh" ~/.claude/hooks/rust-fmt-on-edit.sh
ln -sf "$RUSTCI/agent/claude-rust-check-on-edit.sh" ~/.claude/hooks/rust-check-on-edit.sh
ln -sf "$RUSTCI/agent/claude-rust-stop.sh" ~/.claude/hooks/rust-stop.sh
```

and register them in `~/.claude/settings.json`. Under `hooks.PostToolUse`:

```json
{
  "matcher": "Edit|Write|MultiEdit",
  "hooks": [
    { "type": "command", "command": "\"$HOME\"/.claude/hooks/rust-fmt-on-edit.sh", "timeout": 30 },
    { "type": "command", "command": "\"$HOME\"/.claude/hooks/rust-check-on-edit.sh", "timeout": 120 }
  ]
}
```

and under both `hooks.Stop` and `hooks.SubagentStop`:

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [{ "type": "command", "command": "\"$HOME\"/.claude/hooks/rust-stop.sh", "timeout": 300 }] }
    ],
    "SubagentStop": [
      { "hooks": [{ "type": "command", "command": "\"$HOME\"/.claude/hooks/rust-stop.sh", "timeout": 300 }] }
    ]
  }
}
```

The two edit hooks run in parallel. The cargo check one is optional: it covers the "callers broke" case at the cost of one workspace check per edit (measured on nota, warm, 6 crates and about 1,000 lines: 0.1 to 0.3s for `cargo check -p <crate>` after an edit to a low or a leaf crate, 0.7s for `--workspace` after an edit to the lowest crate, 3.5s for the Stop hook's clippy run).

## Changing rust-ci

A release is one commit tagged `v1.x.y`:

1. Commit the change on `main` (by pull request; see below).
2. Tag that commit `v1.x.y` and push the tag, and move `v1` to it (a convenience for reading; projects pin SHAs):

   ```sh
   git tag v1.x.y && git push origin v1.x.y
   git tag -f v1 v1.x.y && git push -f origin v1
   ```

3. Repoint each project's `ci.yml` pin (the commit SHA, with `# v1.x.y` beside it) and its `lefthook.yml` `ref` together.
4. Never move or delete a `v1.x.y` tag. A repository ruleset ("Release tags") rejects updates and deletions of `v1.*` tags; it doesn't cover the moving `v1` tag.

`rust.yml` refers to its own drift action as `$/actions/baseline-drift`, which GitHub resolves to the commit being run, so a release needs no self-reference edit. actionlint 1.7.12 doesn't know that syntax yet; `.github/actionlint.yaml` excuses only those references.

A branch ruleset ("main checks") requires `self-test`, `actions` and the four `rust-workflow / ...` checks before anything merges into `main`. Repository admins bypass it.

A change that would fail a project that passed before (a stricter lint in the baseline, a new required input, a new job) is a new major version. A baseline change that projects haven't copied yet only warns, through the drift check.

CI runs `tests/test-drift.sh` (the drift check's cases), shellcheck, actionlint and zizmor. It also runs `rust.yml` itself, on pull requests and pushes, against a fixture workspace at this repository's root: `Cargo.toml` (with a copy of the baseline's lint tables), `crates/fixture` (a unit test and a doctest), symlinks to the baseline files, a pre-test action (`.github/actions/pre-test`), and setup and post-test scripts in `tests/` that check the inputs run in order. The `actions` job runs this commit's drift action against the fixture and fails unless it reports no drift. The fixture exists only for these runs; rust-ci isn't a Rust library.
