# rust-ci

Shared CI for gaius-codius Rust projects: one reusable workflow, baseline config files and a drift check that compares a project's copies with them. Projects pin a release by commit SHA and keep their own project-only jobs. The Cargo workspace must be at the repository root.

| Piece | Where | How a project uses it |
|---|---|---|
| Reusable workflow | `.github/workflows/rust.yml` | Called from the project's `ci.yml` |
| Baseline drift check | `actions/baseline-drift` | Run by the workflow's `lint` job; fails on a weakened setting, warns on a missing one |
| New-dependency report | `actions/new-deps` | Run by the workflow's `deps` job on pull requests; reports, never fails |
| Environment guard | `actions/env-guard` | Run by the workflow before each check that project scripts could reach; fails on flags, wrappers or tools they changed |
| Argument check | `actions/check-args` | Run by the workflow on its argument inputs; fails on an argument that makes a check pass without checking |
| Formatting, toolchain, test profiles | `baseline/rustfmt.toml`, `baseline/rust-toolchain.toml`, `baseline/.config/nextest.toml` | Copied to the project as they are |
| Lints | `baseline/workspace-lints.toml` | Its `[workspace.lints]` tables copied into the root `Cargo.toml`; a project may add lints |
| Clippy settings, dependency policy, spelling | `baseline/clippy.toml`, `baseline/deny.toml`, `baseline/typos.toml` | Copied as the start of the project's own file; a project adds settings, bans, exceptions, excludes and words |

## What the workflow checks

Five jobs, and a sixth when the `mutants` input is on, on the runner the caller names. Called from a job with id `rust`, they report as `rust / lint`, `rust / test`, `rust / deps`, `rust / workflows`, `rust / secrets` and `rust / mutants`.

| Job | Steps |
|---|---|
| `lint` | Drift from this baseline (see below); the toolchain from `rust-toolchain.toml`; the setup scripts, then the environment check (see below); `cargo fmt --all --check`; `cargo clippy --workspace --all-targets --locked` (with `--all-features` if `clippy-all-features` is set); `cargo doc --no-deps --document-private-items --workspace --locked` with `RUSTDOCFLAGS=-D warnings`; typos |
| `test` | The argument check on `test-command`; the toolchain; the setup scripts; the project's pre-test action and script; cargo-nextest 0.9.146; the environment check; `cargo nextest run` with the `test-command` arguments; the post-test script (then the environment check again); `cargo test --workspace --locked --doc` |
| `mutants` | Only with the `mutants` input on, and only on `pull_request` events: skipped on others, `merge_group` and `pull_request_target` among them, and a skipped job counts as passed for a required check. The argument check on `mutants-arguments`; the toolchain; the setup scripts; the pre-test action and script; the environment check; cargo-mutants 27.1.0 (with cargo-nextest 0.9.146) on the pull request's diff against its base commit (`cargo mutants --no-config --in-diff`), in place, with the `mutants-arguments`. `--no-config` leaves out the project's `.cargo/mutants.toml`, which a pull request could set to exclude every mutant, so cargo-mutants options go in `mutants-arguments`. A mutant the tests don't catch, or one that times out, fails the job; a diff without Rust code passes |

The workflow needs no Docker and no sudo. The tools it needs are installed with taiki-e/install-action, pinned to release versions. Every job but `mutants` sets `CARGO_BUILD_WARNINGS=deny`, so warnings fail clippy, the docs and the tests.

The project's setup scripts, pre-test action and pre-test and post-test scripts run in the same job as the checks, so the environment guard (`actions/env-guard`) fails the job when they change cargo's flags, wrappers or tools. The argument inputs (`test-command`, `mutants-arguments`, `gitleaks-arguments`, `deny-arguments`) are checked too (`actions/check-args`): an argument that makes its check pass without checking, such as `--no-tests=pass`, fails the job.

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

The drift check compares the project's copies with this release's `baseline/`. A setting the project has with a weaker value, a removed baseline setting (on pull requests), a workspace member without `[lints] workspace = true`, or a root `.cargo/config.toml` that loosens what CI runs is an error; a baseline setting the project doesn't have yet is a warning. Comments and formatting are not compared.

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
       uses: gaius-codius/rust-ci/.github/workflows/rust.yml@<release commit SHA> # v4.x.y
       with:
         setup-scripts: |
           scripts/install-linux-build-deps.sh
   ```

   Pin the full commit SHA of a release tag (`git ls-remote --tags https://github.com/gaius-codius/rust-ci 'v4.*'`), as for any third-party action: the workflow runs with your checkout. The workflow calls its own actions (the drift check, the new-dependency report, the environment guard, the argument check) with GitHub's self-repository syntax (`uses: $/...`), so the actions and baseline always come from the commit you pinned.

   Weakened checks stay in the project's own `rules.yml`: the [weakened-checks](https://github.com/gaius-codius/weakened-checks) action needs a `pull_request` workflow that also runs on `edited`, so that editing the PR body (its `Check changes:` line) runs it again, and the rest of this workflow shouldn't rerun for that.

   Project-only jobs (fuzzing, full or sharded mutation runs, extra platforms, coverage, release builds) stay in the project's `ci.yml` and can `needs: rust`. Steps a project needs inside the shared jobs go in through the inputs: `setup-scripts` for packages and pinned libraries, `pre-test-action` or `pre-test-script` for test data and environment, `post-test-script` for checks that reuse the test build.

   The checks are then named `rust / lint`, `rust / test`, `rust / deps`, `rust / workflows`, `rust / secrets` and, with `mutants: true`, `rust / mutants` (skipped, which counts as passed, on events other than pull requests). `rust / secrets` replaces a project's own gitleaks job (nota's and conspector's `No secrets (gitleaks)` in `rules.yml`); conspector's `gitleaks-arguments: --ignore-gitleaks-allow` is now the default and can go (passing it again is harmless). Update the branch ruleset's required checks once the new names have run green once, or nothing can merge: either the old names never report, or the new ones are not yet known.

3. **Runner.** Public projects use GitHub-hosted runners (the default, `["ubuntu-latest"]`), which are free for them. Never run a self-hosted runner for a public repository: a fork's pull request could run code on the host. A private project can pass its self-hosted labels in `runs-on`.

4. **Code owners.** Copy `baseline/CODEOWNERS` to `.github/CODEOWNERS` and set the owner. It lists the files that control the checks (the lint tables' `Cargo.toml`, `clippy.toml`, `rustfmt.toml`, `.cargo/`, `build.rs`, the toolchain, nextest, `deny.toml`, typos, workflows, actions, zizmor and actionlint config, lefthook config, `.gitleaks.toml`, `.gitleaksignore`, `.gitattributes` and itself). Add the scripts the project passes as `setup-scripts` or `pre-test-script`: they run before clippy and the tests. Then turn on "Require a pull request" with "Require review from Code Owners" in the default branch's ruleset, so a change that loosens a check, whoever or whatever wrote it, can't merge without the owner's approval. The drift check doesn't compare this file.

## Releases

A release is one commit tagged `vN.x.y`, where N is the major version (4 now). A moving `vN` tag points at the latest release of that major; it is a convenience for reading, since projects pin SHAs.

1. Commit the change on `main` (by pull request).
2. Tag that commit `vN.x.y` and push the tag, and move `vN` to it:

   ```sh
   git tag v4.x.y && git push origin v4.x.y
   git tag -f v4 v4.x.y && git push -f origin v4
   ```

3. Repoint each project's `ci.yml` pin (the commit SHA, with `# v4.x.y` beside it).
4. Never move or delete a release tag (`vN.x.y`). A repository ruleset ("Release tags") rejects updates and deletions of release tags.

`rust.yml` refers to its own actions as `$/actions/baseline-drift`, `$/actions/new-deps`, `$/actions/env-guard` and `$/actions/check-args`, which GitHub resolves to the commit being run, so a release needs no self-reference edit. actionlint 1.7.12 doesn't know that syntax yet; `.github/actionlint.yaml` excuses only those references.

A branch ruleset ("main checks") requires `self-test`, `actions` and the `rust-workflow / ...` checks before anything merges into `main`. The ruleset lists each check by name, so a new job in `rust.yml` isn't required until it's added there by hand, once it has run green.

A change that would fail a project that passed before (a stricter lint in the baseline, a new required input, a new job) is a new major version. A new baseline setting that projects haven't copied yet only warns, through the drift check; a changed value (a toolchain bump) fails it until the project copies the change, which it does in the same change as its pin.

v4.0.0 contains no code change to the workflow, actions or baseline over v3.2.0. It removes the Claude Code hooks (`agent/`) and the shared git hooks (`lefthook/`) from this repository; they now live outside it. A project that pulls the lefthook config from this repository through `remotes:` must stop doing so before it moves to v4.
