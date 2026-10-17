# LLM-hardening plan (from the 2026-10-16 audit)

Each lane runs in its own worktree and branch, on files the other lanes don't own.
A box is ticked when its lane's branch is reviewed and verified; the PR link goes beside it.
Several items fail projects that passed before, so they ship together as **v2.0.0**.

## Lane A: drift check (`drift/fail-on-weakening`): verified at 034a8c9, not pushed yet
Owns `actions/baseline-drift/`, `tests/test-drift.sh`, `baseline/clippy.toml`, `clippy.toml`, the drift step and lint checkout in `rust.yml`, README "drift" text.
- [x] 1. Fail when a project setting is weaker than the baseline, and when a PR removes a baseline setting the base branch had; a missing new baseline item still only warns
- [x] 2. Every workspace member must have `[lints] workspace = true`
- [x] 5. `baseline/clippy.toml` (unwrap, expect and panic allowed in tests), compared by the drift check

## Lane B: lints (`lints/llm-patterns`): verified at 228651d, not pushed yet
Owns `baseline/workspace-lints.toml`, root `Cargo.toml`, `crates/fixture/`, `tests/test-warnings-deny.sh`.
- [x] 7. Add `let_underscore_must_use`, `unused_result_ok`, `map_err_ignore`, `unwrap_in_result`, `panic_in_result_fn`, `print_stdout`, `print_stderr`, `exit`
- [x] 9b. Regression test: a planted warning must fail the build (`CARGO_BUILD_WARNINGS=deny`)

## Lane C: workflow (`workflow/llm-gates`): verified at c8f874e, not pushed yet
Owns `rust.yml` (except the drift step), the `rust-workflow` job in `ci.yml`, `actions/new-deps/`, `lefthook/rust.yml`, README inputs and jobs tables.
- [x] 3a. Optional `mutants` input: cargo-mutants on the PR's diff
- [x] 3b. `test-command` default uses `--no-tests=fail`
- [x] 4. New-dependency report: crates added in the `Cargo.lock` diff, as annotations
- [x] 6. `clippy-all-features` input
- [x] 9a. Shared secret scan (gitleaks) in CI and the lefthook pre-commit

## Lane D: agent guard (`agent/protect-config`): verified at 1cb452b, not pushed yet
Owns `agent/claude-rust-protect-config.sh`, `tests/test-protect-hook.sh`, `baseline/CODEOWNERS`, `.github/CODEOWNERS`, README "Claude Code hooks" text.
- [x] 8a. PreToolUse hook asking before an agent edits check config (lints, deny, nextest, clippy, CI workflows)
- [x] 8b. CODEOWNERS template for those files

## Weakened checks
- [x] X2. Not blocked after all: weakened-checks v1.0.0 (a tag, no GitHub release) already runs in nota's and conspector's `rules.yml`. It stays there, since it needs `edited` PR events; rust-ci's docs now say so (#5)

## Release
- [x] Release steps in README and the `v1.*` tag trigger in `ci.yml` updated for v2
- [x] Merged as ffedbbd (https://github.com/gaius-codius/rust-ci/pull/5), tagged `v2.0.0` and `v2`
- [x] "Release tags" ruleset covers `v2.*`
- [x] "main checks" ruleset adds `rust-workflow / secrets` and `rust-workflow / mutants` (8 required checks now)
- [ ] nota moves to v2.0.0: **paused** (292 lint hits). Scheduled as GAI-488 (critical). Config done on local branch `rust-ci-v2` (e874731, not pushed). Decision: `map_err_ignore` carries the source error. Open: how deliberate drops say so
- [x] conspector moves to v2.0.0: https://github.com/gaius-codius/conspector/pull/68 merged as 0748d6b (199 hits fixed, 41 `#[expect]`, each with a reason)
- [ ] Each project drops its own `No secrets (gitleaks)` job and requires `rust / secrets` instead. conspector: done (ruleset swapped; #69 merged as 65de10b). nota: with GAI-488

## Integration
Branch `release/v2-prep` (f4f9177) = main + A + B + D + C + release prep, conflicts resolved (README, `ci.yml` self-test steps, the duplicate `test-drift.sh` fix).
Verified there on 2026-10-16: all 7 `tests/*.sh`, shellcheck, actionlint 1.7.12, zizmor 1.30.1 (offline), clippy with warnings denied, cargo tests, drift check (no drift).
#5's CI ran the GitHub-only paths green: mutants (no fixture code in the diff, so nothing to mutate), new-deps, drift on a PR, `gitleaks git` (no leaks).


# v3.0.0: holes found by the v2.0.0 review (2026-10-17)

Three reviews of `2ef03c2..ffedbbd` (Codex, Cursor, a fresh Claude), each finding re-checked. One PR (https://github.com/gaius-codius/rust-ci/pull/7, all CI green), released as v3.0.0 since it fails projects that passed on v2.

## Lane E: drift (`drift/close-holes`)
Owns `actions/baseline-drift/`, `tests/test-drift.sh`, README drift text.
- [x] E1. Extra `[workspace.lints]` entries: fail on any at `allow`, on `warnings` below deny, and on a group that outranks baseline lints
- [x] E2. `.cargo/config(.toml)`: fail on rustflags, aliases that shadow the checked commands, `build.warnings`, lint-related `[env]`
- [x] E3. `**` member globs are expanded (recursive)
- [x] E4. Unused `[workspace.dependencies]` paths are not members
- [x] E5. `.clippy.toml`, `.rustfmt.toml`, or a nested `clippy.toml`/`rustfmt.toml` fails
- [x] E6. Test/check switches: `test = false`, `autotests = false`, `[profile]` overflow-checks/debug-assertions off, nextest `retries`/`default-filter`, new `workspace.exclude` and deny `ignore` entries against the base

## Lane F: workflow (`workflow/close-holes`)
Owns `rust.yml`, `ci.yml`, `actions/new-deps/`, `lefthook/rust.yml`, README inputs and jobs tables.
- [x] F1. A PR's `.gitattributes` can't hide diffs from gitleaks and mutants
- [x] F2. Setup and pre-test scripts can't change cargo's flags or which `cargo` runs
- [x] F3. cargo-mutants ignores `.cargo/mutants.toml` (`--no-config`)
- [x] F4. gitleaks ignores inline `gitleaks:allow` by default
- [x] F5. cargo-nextest pinned in the mutants job
- [x] F6. Extra-argument inputs reject flags that force a green check
- [x] F7. new-deps: a git dependency's new commit isn't a new crate; `merge_group`/`pull_request_target` caveat documented

## Lane G: agent guard (`agent/close-holes`)
Owns `agent/claude-rust-protect-config.sh`, `tests/test-protect-hook.sh`, `baseline/CODEOWNERS`, `.github/CODEOWNERS`, README hook text.
- [x] G1. Suppressions compared as attributes, not counts (swaps, deny→allow, added lints); Bash regex tolerates whitespace
- [x] G2. More protected files: `.cargo/config*`, `.cargo/mutants.toml`, `.gitattributes`, `.gitleaksignore`, `build.rs`, `.github/zizmor.yml`, `.github/actionlint.yaml`, `lefthook-local.yml`, setup scripts note
- [x] G3. Cargo.toml writes judged by parsed tables, not filtered lines (`[package.metadata]` move)
- [x] G4. Hook asks for `#[should_panic]`, `#[cfg(<target>)]` on tests, `#[rustfmt::skip]`, `gitleaks:allow`
- [x] G5. Removing or narrowing a `deny`/`forbid`/`warn` attribute asks (6a913a3)

## Release
- [x] #7 merged as 39807f2, tagged `v3.0.0`; "Release tags" covers `v3.*`
- [x] v3.0.1 (ac76d25, #8): env guard reads /proc/self/environ, so it works on runners in a PID namespace (office)
- [x] conspector moves to v3.0.1: https://github.com/gaius-codius/conspector/pull/70 merged as 1e627de
