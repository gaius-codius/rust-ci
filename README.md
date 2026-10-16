# rust-ci

Shared quality setup for gaius-codius Rust projects: one reusable CI workflow, baseline config files with a drift check, and shared git hooks. Projects pin a release by commit SHA and keep their own project-only jobs. The Cargo workspace must be at the repository root.

| Piece | Where | How a project uses it |
|---|---|---|
| Reusable workflow | `.github/workflows/rust.yml` | Called from the project's `ci.yml` |
| Baseline drift check | `actions/baseline-drift` | Run by the workflow's `lint` job; fails on a weakened setting, warns on a missing one |
| New-dependency report | `actions/new-deps` | Run by the workflow's `deps` job on pull requests; reports, never fails |
| Formatting, toolchain, test profiles | `baseline/rustfmt.toml`, `baseline/rust-toolchain.toml`, `baseline/.config/nextest.toml` | Copied to the project as they are |
| Lints | `baseline/workspace-lints.toml` | Its `[workspace.lints]` tables copied into the root `Cargo.toml`; a project may add lints |
| Clippy settings, dependency policy, spelling | `baseline/clippy.toml`, `baseline/deny.toml`, `baseline/typos.toml` | Copied as the start of the project's own file; a project adds settings, bans, exceptions, excludes and words |
| Git hooks | `lefthook/rust.yml` | Loaded through lefthook `remotes:`, pinned to a tag |
| Claude Code hooks | `agent/claude-rust-*.sh` | Symlinked into `~/.claude/hooks/` and registered in `~/.claude/settings.json` (user-level, once per machine) |
| What moved where | `docs/inventory.md` | Every job, step and hook of nota and conspector, marked shared or project-only |

## What the workflow checks

Five jobs, and a sixth when the `mutants` input is on, on the runner the caller names. Called from a job with id `rust`, they report as `rust / lint`, `rust / test`, `rust / deps`, `rust / workflows`, `rust / secrets` and `rust / mutants`.

| Job | Steps |
|---|---|
| `lint` | Drift from this baseline (see below); the toolchain from `rust-toolchain.toml`; the setup scripts, then the environment check (see below); `cargo fmt --all --check`; `cargo clippy --workspace --all-targets --locked` (with `--all-features` if `clippy-all-features` is set); `cargo doc --no-deps --document-private-items --workspace --locked` with `RUSTDOCFLAGS=-D warnings`; typos |
| `test` | The argument check on `test-command`; the toolchain; the setup scripts; the project's pre-test action and script; cargo-nextest 0.9.146; the environment check; `cargo nextest run` with the `test-command` arguments; the post-test script (then the environment check again); `cargo test --workspace --locked --doc` |
| `mutants` | Only with the `mutants` input on, and only on `pull_request` events: skipped on others, `merge_group` and `pull_request_target` among them, and a skipped job counts as passed for a required check. The argument check on `mutants-arguments`; the toolchain; the setup scripts; the pre-test action and script; the environment check; cargo-mutants 27.1.0 (with cargo-nextest 0.9.146) on the pull request's diff against its base commit (`cargo mutants --no-config --in-diff`), in place, with the `mutants-arguments`. `--no-config` leaves out the project's `.cargo/mutants.toml`, which a pull request could set to exclude every mutant, so cargo-mutants options go in `mutants-arguments`. A mutant the tests don't catch, or one that times out, fails the job; a diff without Rust code passes |
| `deps` | On pull requests, the crates the pull request adds to `Cargo.lock` (annotations and a job summary; never fails); the argument check on `deny-arguments`; the toolchain; `cargo deny check` (`--all-features --locked`, cargo-deny 0.20.2); `cargo shear` |
| `workflows` | actionlint 1.7.12 (release binary, checked against a pinned digest); zizmor 1.30.1 (regular persona, online audits) |
| `secrets` | The argument check on `gitleaks-arguments`; gitleaks 8.30.1 (release binary, checked against a pinned digest), secrets redacted in the log, inline `gitleaks:allow` comments ignored (`--ignore-gitleaks-allow`) unless `gitleaks-allow-comments` is on. On `pull_request` events, every commit of the pull request (`gitleaks git --log-opts=<base>..HEAD`), so a secret added in one commit and deleted in a later one is still found: it stays in the history once merged. On other events, `merge_group` and `pull_request_target` among them, the files in the checkout (`gitleaks dir .`), which needs no history and doesn't fail again on a secret removed and rotated long ago, but doesn't see a secret a commit added and a later one removed. gitleaks reads the project's `.gitleaks.toml` and `.gitleaksignore` at the root by itself |

The workflow needs no Docker and no sudo, so it runs on a self-hosted Linux x64 runner that has only rustup (no toolchain installed), git, curl, bash and python3. The tools it needs are installed with taiki-e/install-action, which downloads pinned release binaries (actionlint and gitleaks are downloaded directly and checked against pinned digests).

Every job but `mutants` sets `CARGO_BUILD_WARNINGS=deny`, so warnings fail clippy, the docs and the tests. (A mutant often leaves a warning, such as an unused argument; denied, it would fail to build and go untested.) The `lint`, `test` and `mutants` jobs cache the build with Swatinem/rust-cache, or, with `target-dir` set, keep it on the runner.

The project's setup scripts, pre-test action and pre-test and post-test scripts run in the same job as the checks, so the jobs guard against them (`actions/env-guard`). Right after the toolchain is installed, before any project code, a step records where `cargo`, `rustc`, `git` and `bash` are and which `HOME`, `CARGO_HOME` and `RUSTUP_HOME` are in use. Before clippy and formatting (when there are setup scripts), before the tests, before the doctests (after a post-test script) and before the mutants, a check fails the job if `$GITHUB_ENV` has set a variable that changes how the code is built, linted or tested (`RUSTFLAGS`, `RUSTDOCFLAGS` and their `CARGO_BUILD_`/`CARGO_ENCODED_` forms, `RUSTC`, `RUSTDOC`, `CARGO`, the rustc wrappers, `CLIPPY_ARGS`, `CLIPPY_CONF_DIR`, `RUSTUP_TOOLCHAIN`, `RUSTC_BOOTSTRAP`, any `NEXTEST_*`, `CARGO_MUTANTS_*`, `CARGO_ALIAS_*` or `CARGO_HOST_*`, a target's runner, linker or rustflags, a profile's `overflow-checks` or `debug-assertions`, `CARGO_BUILD_WARNINGS` other than the job's), a variable bash or the loader reads at startup (`BASH_ENV`, `SHELLOPTS`, `LD_PRELOAD` and the like) or an exported shell function, or if `$GITHUB_PATH` has put another `cargo`, `cargo-clippy`, `cargo-fmt`, `rustc`, `rustdoc`, `git` or `bash` first, or cargo-nextest and cargo-mutants aren't the ones install-action installed. The check runs under `/bin/bash --posix` with those startup variables blanked, so it can't be talked out of running. Other variables (`CARGO_TARGET_DIR`, `LD_LIBRARY_PATH`, the project's own) pass. The guard doesn't see a script that edits files: the Cargo config in `CARGO_HOME` or the repository, the installed tools, the build directory. So list the scripts' paths (and the pre-test action, and `.cargo/`) in `CODEOWNERS`, which makes a change to them need the owner's review like the workflow itself.

The argument inputs are checked too (`actions/check-args`), before anything from the project runs, in both `--flag value` and `--flag=value` forms and inside a cluster of short flags. Each fails the job on an argument that makes its check pass without checking, or replaces one the job passes itself:

- `test-command`: `--no-tests=pass` or `warn`, `--retries`, `--flaky-result=pass`, `--no-run`, `--partition`, `--rerun`/`-R`, `--run-ignored only` (or `-- --ignored`), `--debugger`, `--tracer`, an archive or prebuilt binaries (`--archive-file`, `--binaries-metadata`, `--cargo-metadata`, the `--*-remap` options), `--manifest-path`, and another cargo or nextest config (`--config`, `--config-file`, `--user-config-file`, `--tool-config-file`). Filters (`-E`, `-p`, test names after `--`) are allowed: `--no-tests=fail` catches one that matches nothing, but one that leaves tests out is for the reviewer to see.
- `mutants-arguments`: `--list`, `--list-files`, `--check`, the filters (`--exclude`/`-e`, `--exclude-re`/`-E`, `--re`/`-F`, `--file`/`-f`, `--package`/`-p`), `--dir`, `--manifest-path`, `--shard`, `--iterate`, `--baseline`, and the job's own `--in-diff`, `--in-place`, `--output`, `--no-config` and `--config`. Options that change how mutants run (`--test-tool`, `--timeout`, `--jobs`, `--test-workspace`, `--cap-lints`, `--skip-calls`, cargo test arguments after `--`) are allowed; a test run that runs nothing leaves every mutant missed, which fails.
- `gitleaks-arguments`: `--exit-code`, `--baseline-path`/`-b`, `--enable-rule`, `--gitleaks-ignore-path`/`-i`, `--config`/`-c` (use `gitleaks-config`), `--log-opts`, `--pre-commit` and `--staged`.
- `deny-arguments`: `--config` (another `deny.toml`), `--manifest-path`, `--metadata-path`, `--exclude`, and a subcommand.
- Every one: `--help`, `-h` and `--version`, which print and exit 0.

A pull request's own `.gitattributes` can mark a file `binary` or `-diff`, which makes `git log -p` and `git diff` print "Binary files differ" in place of the change. The `secrets` and `mutants` jobs write `* diff` to `$GIT_DIR/info/attributes`, which comes before every `.gitattributes`, so every file's change is scanned and mutated as text (`tests/test-gitattributes.sh`).

Inputs:

| Input | Default | Meaning |
|---|---|---|
| `runs-on` | `'["ubuntu-latest"]'` | Runner labels as a JSON list |
| `timeout-minutes` | `60` | Timeout of each job (GitHub's default is 6 hours) |
| `setup-scripts` | `""` | Scripts the `lint`, `test` and `mutants` jobs run before building, one per line, each a path with optional arguments: native build dependencies, pinned libraries. The environment check runs after them |
| `cache-key-files` | `""` | A glob of files hashed into the build cache's key, for example a script that pins a native library |
| `target-dir` | `""` | Persistent self-hosted runners: an absolute directory that keeps each job's build between runs (`<target-dir>/<owner>/<repo>/<job>`) in place of the GitHub cache, which is slower there than an incremental build. Prune it on the runner |
| `pre-test-action` | `false` | Run the project's composite action at `.github/actions/pre-test` before the tests. For setup that needs other actions (a cache) or sets variables for the tests (written to `$GITHUB_ENV`; the environment check refuses the ones above) |
| `pre-test-script` | `""` | A script run before the tests |
| `test-command` | `cargo nextest run --workspace --locked --profile ci --no-tests=fail` | The test run, written out in full so the project's own checks can read its arguments in `ci.yml`. Must start with `cargo nextest run`; the arguments are split on spaces. `--no-tests=fail` fails a run that finds no tests. Arguments that pass tests without running them fail the job (see the argument check above), `--no-tests=pass` among them, so a workspace needs a test. Changed in v2.0.0 (v1 defaulted to `--no-tests=pass`) |
| `post-test-script` | `""` | A script run after the tests, for checks that reuse the test build |
| `doctest` | `true` | Run doctests. Turn off while the workspace has no library crate (`cargo test --doc` fails without one) |
| `clippy-all-features` | `false` | Run clippy with `--all-features`, so code behind features is linted too |
| `doc-all-features` | `false` | Build the docs with `--all-features` |
| `deny-arguments` | `--all-features --locked` | Arguments to `cargo deny`, before `check` (see the argument check above) |
| `gitleaks-config` | `""` | A gitleaks config for the `secrets` job, a path from the repository root. Only needed for a config elsewhere: gitleaks reads `.gitleaks.toml` at the root by itself |
| `gitleaks-arguments` | `""` | Extra arguments to gitleaks, split on spaces (see the argument check above) |
| `gitleaks-allow-comments` | `false` | Honour inline `gitleaks:allow` comments. Off, the job passes `--ignore-gitleaks-allow`, so a secret can't be waved through in the change that adds it; `.gitleaksignore` still applies |
| `mutants` | `false` | Add the `mutants` job (`pull_request` events only) |
| `mutants-arguments` | `""` | Extra arguments to `cargo mutants`, split on spaces, for example `--test-tool nextest` (cargo-nextest is installed) or `--timeout 120`. The job already passes `--in-diff`, `--in-place`, `--output` and `--no-config`, so options a project would keep in `.cargo/mutants.toml` go here (see the argument check above) |

The drift check compares the project's copies with this release's `baseline/`:

- `rustfmt.toml` and `rust-toolchain.toml` must hold exactly the baseline's settings.
- `.config/nextest.toml`, `clippy.toml`, `deny.toml`, `typos.toml` and the `[workspace.lints]` tables in `Cargo.toml` must hold every baseline setting with the baseline's value or a stricter one; a list must hold at least the baseline's items. A project's own additions are not drift.
- Every workspace member's `Cargo.toml` (the root package, the `members` globs and path dependencies inside the workspace, less `exclude`) must have `[lints] workspace = true` and nothing else in `[lints]`.
- Comments and formatting are not compared.

Each difference is an annotation on the `lint` job. These are errors, and fail the job:

- A setting the project has with a weaker value. Stricter is fine where values have an order: lint levels (`allow` < `warn` < `deny` < `forbid`; a `{ level, priority }` table compares by level, and its priority must equal the baseline's), cargo-deny severities (`allow` < `warn` < `deny`), the scope of `advisories.unmaintained` and `unsound` (`all` covers `workspace` and `transitive`; `none` covers neither), a higher `licenses.confidence-threshold`, and `false` for clippy's `allow-*-in-tests`. Any other value that differs from the baseline's is an error, as is a setting in `rustfmt.toml` or `rust-toolchain.toml` that isn't in the baseline. A toolchain other than the baseline's is drift too: bump `rust-toolchain.toml` in the same change as the pin.
- On a pull request, a baseline setting, list item or file the project had at the pull request's base commit and no longer has. The `lint` job fetches the full history on pull requests to read the base.
- A workspace member that doesn't take the workspace lints, or a file that can't be parsed.

A baseline setting, list item or file the project doesn't have yet (and didn't have at the base) is a warning: that is how a new baseline item reaches projects that haven't copied it.

The new-dependency report compares `Cargo.lock` at the pull request's base commit with the pull request's. A crate the base didn't have from that source (a new dependency, or a known crate from a new registry or repository) is a warning; a new version of a crate the base had from the same source is a notice. Workspace members and path dependencies are left out, since the diff shows them. Every new package, with its version and source, also goes into a table in the job summary, which is the full list (GitHub shows at most 10 warnings and 10 notices per step). The report never fails the job: adding a crate is often the right change, and whether a crate is trustworthy and worth what it brings is a reviewer's judgement, not a rule a script can hold. cargo-deny still fails on a banned crate, a disallowed licence or source, or an advisory.

## Adopting it

Run these from the project's root.

1. **Baseline files.**

   ```sh
   RUSTCI=/path/to/rust-ci   # a clone of this repo at the tag you pin
   cp "$RUSTCI/baseline/rustfmt.toml" "$RUSTCI/baseline/rust-toolchain.toml" "$RUSTCI/baseline/clippy.toml" .
   mkdir -p .config && cp "$RUSTCI/baseline/.config/nextest.toml" .config/
   ```

   Copy the two tables in `baseline/workspace-lints.toml` into the root `Cargo.toml`, give every member crate's `Cargo.toml` `[lints] workspace = true`, and start `deny.toml` and `typos.toml` from the baseline's, adding the project's own bans, licence exceptions, excludes and words. A project's own clippy settings go in `clippy.toml` after the baseline's. Keep `rust-version` in `Cargo.toml` equal to the toolchain.

   Besides clippy's pedantic group, the lints reject `unwrap`, `expect`, `panic!`, `todo!` and `dbg!`; errors dropped with `let _ =`, a discarded `.ok()` or `.map_err(|_| ...)`; unwrapping or panicking in a function that returns `Result`; `print!`, `eprint!` and `std::process::exit`. A binary writes its output through a writer such as `std::io::stdout().lock()`, or under `#[expect(clippy::print_stdout, reason = "...")]`, and returns an `ExitCode` from `main`. Each lint is "warn"; the workflow's `CARGO_BUILD_WARNINGS=deny` makes it fail CI.

2. **CI.** Replace the project's lint, test, deps and workflow-lint jobs in `.github/workflows/ci.yml`:

   ```yaml
   permissions:
     contents: read

   jobs:
     rust:
       uses: gaius-codius/rust-ci/.github/workflows/rust.yml@<release commit SHA> # v2.x.y
       with:
         setup-scripts: |
           scripts/install-linux-build-deps.sh
   ```

   Pin the full commit SHA of a release tag (`git ls-remote --tags https://github.com/gaius-codius/rust-ci 'v2.*'`), as for any third-party action: the workflow runs with your checkout. The workflow calls its own actions (the drift check, the new-dependency report) with GitHub's self-repository syntax (`uses: $/...`), so the actions and baseline always come from the commit you pinned.

   Weakened checks stay in the project's own `rules.yml`: the [weakened-checks](https://github.com/gaius-codius/weakened-checks) action needs a `pull_request` workflow that also runs on `edited`, so that editing the PR body (its `Check changes:` line) runs it again, and the rest of this workflow shouldn't rerun for that.

   Project-only jobs (fuzzing, full or sharded mutation runs, extra platforms, coverage, release builds) stay in the project's `ci.yml` and can `needs: rust`. Steps a project needs inside the shared jobs go in through the inputs: `setup-scripts` for packages and pinned libraries, `pre-test-action` or `pre-test-script` for test data and environment, `post-test-script` for checks that reuse the test build.

   The checks are then named `rust / lint`, `rust / test`, `rust / deps`, `rust / workflows`, `rust / secrets` and, with `mutants: true`, `rust / mutants` (skipped, which counts as passed, on events other than pull requests). `rust / secrets` replaces a project's own gitleaks job (nota's and conspector's `No secrets (gitleaks)` in `rules.yml`); conspector's `gitleaks-arguments: --ignore-gitleaks-allow` is now the default and can go (passing it again is harmless). Update the branch ruleset's required checks once the new names have run green once, or nothing can merge: either the old names never report, or the new ones are not yet known.

3. **Runner.** Public projects use GitHub-hosted runners (the default, `["ubuntu-latest"]`), which are free for them. Never run a self-hosted runner for a public repository: a fork's pull request could run code on the host. A private project can pass its self-hosted labels in `runs-on`.

4. **Git hooks.** Add the shared hooks to the project's `lefthook.yml`, and delete the project's own commands of the same names (`fmt`, `typos`, `secrets`, `workflows`, `deny`, `shear`):

   ```yaml
   remotes:
     - git_url: https://github.com/gaius-codius/rust-ci
       ref: v2.x.y   # the release your ci.yml pins
       configs:
         - lefthook/rust.yml
   ```

   then `lefthook install`. A remote's command overrides the project's command of the same name, so a project that needs a different form (other arguments, a wrapper) keeps it under another name. From v2.0.0 that includes `secrets`: the shared command is `gitleaks git --pre-commit --staged --redact --verbose --no-banner --ignore-gitleaks-allow` (it needs gitleaks on PATH), and it replaces a project command named `secrets` as soon as the project moves its `ref` to v2. nota and conspector both have a `secrets` command with other flags (conspector's has `--ignore-gitleaks-allow`), so each either drops its own or renames it before moving the `ref`. `ref` must be a tag or branch (lefthook can't fetch a commit SHA), and it moves with the CI pin. If lefthook can't fetch the remote (offline, a tag that doesn't exist yet) it says "Couldn't sync" and carries on without these hooks, so check that `lefthook dump` lists them.

5. **Code owners.** Copy `baseline/CODEOWNERS` to `.github/CODEOWNERS` and set the owner. It lists the files that control the checks (the lint tables' `Cargo.toml`, `clippy.toml`, `rustfmt.toml`, the toolchain, nextest, `deny.toml`, typos, workflows, actions, `lefthook.yml`, `.gitleaks.toml` and itself). Then turn on "Require a pull request" with "Require review from Code Owners" in the default branch's ruleset, so a change that loosens a check, whoever or whatever wrote it, can't merge without the owner's approval. The drift check doesn't compare this file.

## Claude Code hooks

Four user-level hooks for Claude Code agents, needing `jq` and, for the cargo ones, `cargo`. They share one rule: an outcome of exit 2 means "the check ran and found problems". A tool failure (a missing binary, a failed dependency fetch, a crashed tool, a held cargo build lock) never blocks; it goes out as `additionalContext` saying what could not run. Nothing is skipped silently. Tests (fake hook input, fake `cargo` and `rustfmt`, so no Rust build): `tests/test-fmt-hook.sh`, `tests/test-check-hook.sh`, `tests/test-stop-hook.sh`.

| Hook | Event | What it does |
|---|---|---|
| `agent/claude-rust-fmt-on-edit.sh` | `PostToolUse`, `Edit\|Write\|MultiEdit` | After a `.rs` edit: `rustfmt --edition <E> <file>`, with the edition from `edition` in the package's `Cargo.toml` or `[workspace.package]` (the baseline `rustfmt.toml` sets only `style_edition`, so a bare `rustfmt` would parse as edition 2015). A file that doesn't parse is exit 2 with rustfmt's message; a missing rustfmt is a tool failure |
| `agent/claude-rust-check-on-edit.sh` | `PostToolUse`, `Edit\|Write\|MultiEdit` | After a `.rs` edit: `cargo check --workspace --message-format=json`. Errors are reported wherever they are (an edit can break callers in crates it never touched); warnings only for the edited file. Doesn't wait for a held build lock |
| `agent/claude-rust-protect-config.sh` | `PreToolUse`, `Edit\|Write\|MultiEdit\|Bash` | Before a change to a file that controls the checks, answers `ask`, so you approve it: `deny.toml`, `clippy.toml`, `.clippy.toml`, `rustfmt.toml`, `rust-toolchain.toml`, `.config/nextest.toml`, `typos.toml`, `_typos.toml`, `.github/workflows/*`, `.github/actions/**`, `lefthook.yml`, `.gitleaks.toml`, `CODEOWNERS`; a `Cargo.toml` only when the change touches `[lints]` or `[workspace.lints]` (or the hook can't tell); a `.rs` edit that adds `#[allow(`, `#![allow(`, `#[expect(`, `#[ignore` or `#[cfg(any())]`. Paths are relative to the git root, which must have a `Cargo.toml`. Bash commands are checked best effort (`sed -i`, `tee`, `>`, `mv`, `cp`, `rm`, `git checkout` and the like naming one of those files); a write through another program isn't seen. `RUST_CI_PROTECT_CONFIG=off` (in the environment Claude Code starts in, or `env` in settings) turns it off. Test: `tests/test-protect-hook.sh` |
| `agent/claude-rust-stop.sh` | `Stop` and `SubagentStop` | `cargo clippy --workspace --all-targets --message-format=json` when Rust files changed against the merge-base with `origin/main` (committed, staged, unstaged or untracked; nothing changed is silent). Every error is reported wherever it is; warnings only in changed files, so the backlog doesn't nag. Clippy's suggested replacements are shown, never applied. Findings block the stop (exit 2) |

The Stop hook can't loop. When `stop_hook_active` is true and the findings equal the last blocking set (a hash of the checked tree plus a hash of the diagnostics, kept in `rust-ci-stop-hook/` under the git dir), it exits 0 and reports them through `additionalContext` instead of blocking. On `Stop`, `additionalContext` makes Claude continue the turn, so each distinct non-blocking report (that one, a tool failure, a held lock) is delivered that way once; an identical repeat goes out only as `systemMessage`, which shows to you and doesn't continue the turn. If the agent is running cargo itself and holds the build lock, the hook reports that instead of waiting.

Stop doesn't run when you interrupt Claude, so CI remains the gate.

Install once per machine, from a clone of this repo:

```sh
mkdir -p ~/.claude/hooks
ln -sf "$RUSTCI/agent/claude-rust-fmt-on-edit.sh" ~/.claude/hooks/rust-fmt-on-edit.sh
ln -sf "$RUSTCI/agent/claude-rust-check-on-edit.sh" ~/.claude/hooks/rust-check-on-edit.sh
ln -sf "$RUSTCI/agent/claude-rust-stop.sh" ~/.claude/hooks/rust-stop.sh
ln -sf "$RUSTCI/agent/claude-rust-protect-config.sh" ~/.claude/hooks/rust-protect-config.sh
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

and under `hooks.PreToolUse`:

```json
{
  "matcher": "Edit|Write|MultiEdit|Bash",
  "hooks": [
    { "type": "command", "command": "\"$HOME\"/.claude/hooks/rust-protect-config.sh", "timeout": 10 }
  ]
}
```

The protect-config hook only asks; it isn't a gate (an agent can still write through a program it doesn't see, and you can approve). The gate is code-owner review ("Adopting it", step 5).

The two edit hooks run in parallel. The cargo check one is optional: it covers the "callers broke" case at the cost of one workspace check per edit (measured on nota, warm, 6 crates and about 1,000 lines: 0.1 to 0.3s for `cargo check -p <crate>` after an edit to a low or a leaf crate, 0.7s for `--workspace` after an edit to the lowest crate, 3.5s for the Stop hook's clippy run).

## Changing rust-ci

A release is one commit tagged `vN.x.y`, where N is the major version (2 now):

1. Commit the change on `main` (by pull request; see below).
2. Tag that commit `vN.x.y` and push the tag, and move `vN` to it (a convenience for reading; projects pin SHAs):

   ```sh
   git tag v2.x.y && git push origin v2.x.y
   git tag -f v2 v2.x.y && git push -f origin v2
   ```

3. Repoint each project's `ci.yml` pin (the commit SHA, with `# v2.x.y` beside it) and its `lefthook.yml` `ref` together.
4. Never move or delete a release tag. A repository ruleset ("Release tags") rejects updates and deletions of `v1.*` and `v2.*` tags; it doesn't cover the moving `v1` and `v2` tags. A new major version adds its pattern to that ruleset and to the tag trigger in `ci.yml`.

`rust.yml` refers to its own actions as `$/actions/baseline-drift` and `$/actions/new-deps`, which GitHub resolves to the commit being run, so a release needs no self-reference edit. actionlint 1.7.12 doesn't know that syntax yet; `.github/actionlint.yaml` excuses only those references.

A branch ruleset ("main checks") requires `self-test`, `actions` and the `rust-workflow / ...` checks before anything merges into `main`. Repository admins bypass it. The ruleset lists each check by name, so a new job in `rust.yml` isn't required until it's added there: `rust-workflow / secrets` and `rust-workflow / mutants` have to be added by hand once they've run green once.

A change that would fail a project that passed before (a stricter lint in the baseline, a new required input, a new job) is a new major version. A new baseline setting that projects haven't copied yet only warns, through the drift check; a changed value (a toolchain bump) fails it until the project copies the change, which it does in the same change as its pin. v2.0.0 is one: its baseline adds `let_underscore_must_use`, `unused_result_ok`, `map_err_ignore`, `unwrap_in_result`, `panic_in_result_fn`, `print_stdout`, `print_stderr` and `exit`, and the drift check fails on weakened settings.

v2.0.0 is the first major version after v1. What can fail a project that passed on v1:

- `test-command` defaults to `--no-tests=fail`. A project with no tests yet passes its command with `--no-tests=pass`.
- The new `secrets` job runs gitleaks on every project, and the shared lefthook `secrets` command replaces a project's own command of that name.
- The baseline adds eight clippy lints (see "Changing rust-ci" above), and the drift check fails on a weakened or removed baseline setting and on a member crate without `[lints] workspace = true`.

CI runs `tests/test-drift.sh` (the drift check's cases), `tests/test-new-deps.sh` (the new-dependency report's cases, on `Cargo.lock` pairs in a temporary repository), `tests/test-check-args.sh` (the argument check's cases), `tests/test-env-guard.sh` (the environment check against a fake toolchain), `tests/test-gitattributes.sh` (a pull request's `.gitattributes` hiding a planted secret from `git diff` and gitleaks), `tests/test-warnings-deny.sh` (clippy on a copy of the fixture with an `unwrap` planted must fail with `CARGO_BUILD_WARNINGS=deny`, and pass without the plant), shellcheck, actionlint and zizmor. It also runs `rust.yml` itself, on pull requests and pushes, against a fixture workspace at this repository's root: `Cargo.toml` (with a copy of the baseline's lint tables), `crates/fixture` (a unit test and a doctest), symlinks to the baseline files, a pre-test action (`.github/actions/pre-test`), and setup and post-test scripts in `tests/` that check the inputs run in order. The `actions` job runs this commit's drift action against the fixture and fails unless it reports no drift. The fixture exists only for these runs; rust-ci isn't a Rust library.
