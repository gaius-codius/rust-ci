# Inventory: what moved into rust-ci

Every job and step in nota's and conspector's workflows and git hooks when they adopted rust-ci (v1.0.0), and where each one runs now. "Shared" runs in `rust.yml` (checks named `rust / <job>`); "hook" means a project script or action that a shared job runs through an input; "project" stays in the project's own workflow.

## nota: `.github/workflows/ci.yml`

| Job (old check name) | Step | Now |
|---|---|---|
| lint (`fmt, clippy, typos`) | checkout, `rustup toolchain install`, rust-cache keyed on `scripts/sherpa-onnx.sh` | Shared, `rust / lint` (`cache-key-files: scripts/sherpa-onnx.sh`) |
| | `scripts/install-linux-build-deps.sh` | Hook: `setup-scripts` |
| | `scripts/sherpa-onnx.sh` (the pinned sherpa-onnx libraries) | Hook: `setup-scripts` |
| | `sherpa-onnx.test.sh`, `check-weakened.test.sh`, `check-files.test.sh`, `check-clippy-bans.test.sh`, `check-test-targets.test.sh`, `soak-analyse.test.sh`, `lazyfs-crash.test.sh`, `check-clippy-bans.sh` | Project: new job `Script tests` (none of them builds Rust) |
| | `cargo fmt --all --check` | Shared, `rust / lint` |
| | `cargo clippy --workspace --all-targets --locked` (warnings denied) | Shared, `rust / lint` |
| | `cargo doc --no-deps --document-private-items --workspace --all-features --locked` | Shared, `rust / lint` (`doc-all-features: true`) |
| | typos | Shared, `rust / lint` |
| test (`Tests (Linux)`) | checkout, toolchain, cache, sherpa-onnx, build deps | Shared, `rust / test`, with the same `setup-scripts` |
| | Restore the test models (actions/cache), ffmpeg for the fixture on a miss, `scripts/fetch-test-models.sh` (checks every model's SHA-256) | Hook: `.github/actions/pre-test` (`pre-test-action: true`) |
| | `NOTA_REQUIRE_TEST_MODELS=1` | Hook: the pre-test action writes it to `$GITHUB_ENV` |
| | install cargo-nextest | Shared, `rust / test` |
| | `cargo nextest run --workspace --all-targets --locked --profile ci --no-tests=fail` | Shared, `rust / test`; the arguments are the `test-command` input, so `check-test-targets.sh --gates` still reads them in `ci.yml` |
| | `scripts/check-test-targets.sh` | Hook: `post-test-script` (reuses the test build) |
| | `cargo test --workspace --locked --doc` | Shared, `rust / test` (`doctest`, on by default) |
| deps (`Dependencies (cargo-deny, cargo-shear)`) | cargo-deny `--all-features --locked`, cargo-shear | Shared, `rust / deps` |
| workflows (`Workflow lint (actionlint, zizmor)`) | actionlint 1.7.12 (by digest), zizmor 1.30.1 | Shared, `rust / workflows` |
| no-gpl | the `--no-tts` release build and `check-no-gpl.sh` | Project |
| fuzz | cargo-afl build and clippy of `fuzz/` | Project |
| mutants-shard, mutants | cargo-mutants on the PR's diff, and the aggregator | Project |
| build | macOS and Windows builds | Project |
| coverage-scope, coverage | cargo-llvm-cov, report only | Project |

`mutants.yml` (the weekly full mutation run) is project-only.

## nota: `.github/workflows/rules.yml`

| Job | Now |
|---|---|
| files (`No recordings or large files`) | Project (`scripts/check-files.sh` differs per project) |
| weakened (`Weakened checks are explained`) | Project until the weakened-checks detector replaces `scripts/check-weakened.sh` (R3); then the `rules` job (X2, coming) |
| secrets (`No secrets (gitleaks)`) | Project |

## conspector: `.github/workflows/ci.yml`

| Job (old check name) | Step | Now |
|---|---|---|
| lint (`fmt, clippy, typos`) | checkout, toolchain, cache, fmt, clippy, `cargo doc` (no `--all-features`), typos | Shared, `rust / lint` |
| test (`Tests (Linux)`) | checkout, toolchain, cache, nextest `--workspace --locked --profile ci --no-tests=pass` | Shared, `rust / test` (the default `test-command`) |
| | doctests: none yet (no library crate) | Shared, `rust / test` with `doctest: false` until the first library crate |
| deps (`Dependencies (cargo-deny, cargo-shear)`) | cargo-deny, cargo-shear | Shared, `rust / deps` |
| workflows (`Workflow lint (actionlint, zizmor)`) | actionlint, zizmor | Shared, `rust / workflows` |

## conspector: `.github/workflows/rules.yml`

| Job | Now |
|---|---|
| files (`No large files`), from the base's copy of the script | Project |
| weakened (`Weakened checks are explained`), from the base's copy | Project until R3; then the `rules` job (X2, coming) |
| script-tests (`Script tests`): `check-scripts.test.sh`, which includes the audit-parity tests | Project |
| secrets (`No secrets (gitleaks)`, `--ignore-gitleaks-allow`) | Project |

`scripts/check-credential-leak.sh` needs a systemd user manager and is run by hand, not in CI; it stays project-only. `scripts/audit-parity.sh` is tested in `Script tests` above.

## Git hooks (`lefthook.yml`)

| Hook | Command | Now |
|---|---|---|
| pre-commit | `fmt` (`cargo fmt --all --check`), `typos`, `workflows` (actionlint and zizmor) | Shared, `lefthook/rust.yml` |
| pre-commit | `files`, `secrets` (gitleaks flags differ), nota's `clippy-bans`, conspector's `check-scripts` | Project |
| pre-push | `deny`, `shear` | Shared, `lefthook/rust.yml` |
| pre-push | `clippy`, `doc`, `test`, `weakened`; nota's `clippy-fuzz`, `test-targets`, `script-tests`, `doctest` | Project (the arguments differ, conspector runs them through `without-git-env.sh`, and nota's `check-test-targets.sh` reads its `test` line) |

## Baseline files

| File | Compared | nota | conspector |
|---|---|---|---|
| `rustfmt.toml` | exactly | same | same |
| `rust-toolchain.toml` (1.98.1) | exactly | same | same |
| `.config/nextest.toml` | baseline keys | same | same |
| `[workspace.lints]` in `Cargo.toml` | baseline keys | adds `print_stdout`, `print_stderr` | same |
| `deny.toml` | baseline keys; lists must hold the baseline's items | adds the `[bans]` wrappers and two MPL-2.0 exceptions | adds `MPL-2.0` to `allow`, and the async-runtime bans |
| `typos.toml` | baseline keys; lists must hold the baseline's items | adds image excludes and four words | same |

Comments are not compared, so the projects' own comments (which name the project) don't count as drift.
