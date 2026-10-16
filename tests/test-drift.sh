#!/usr/bin/env bash
# Tests actions/baseline-drift/drift.py: a project made of the baseline's own
# files has no drift; a weakened or changed setting, a setting removed since
# the base commit, and a member that doesn't take the workspace lints are
# errors (exit 1); a setting the project hasn't copied yet is a warning (exit
# 0). Needs bash, git and python3 (3.11 or later).
set -uo pipefail

src_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# drift.py finds the baseline relative to itself, so run a copy of the layout.
mkdir -p "${work}/rust-ci/actions/baseline-drift"
cp "${src_root}/actions/baseline-drift/drift.py" "${work}/rust-ci/actions/baseline-drift/"
cp -R "${src_root}/baseline" "${work}/rust-ci/baseline"

# Prepended to each case's commands: commit_base makes the project a git
# repository whose HEAD is the project as it stands, the base commit.
helpers='commit_base() {
  git init -q && git add -A &&
    git -c user.name=test -c user.email=test@example.com commit -q -m base
}'

failures=0

# run_case <name> <exit status> <expected output substring> <unexpected substring or "">
# Sets up the project from the baseline, applies the commands on stdin, then
# runs drift.py in it, with DRIFT_BASE_REF set to $BASE_REF.
run_case() {
  local name="$1" want_code="$2" want="$3" unwanted="$4" out code
  rm -rf "${work}/project" && mkdir -p "${work}/project/.config"
  local b="${work}/rust-ci/baseline"
  cp "${b}/rustfmt.toml" "${b}/rust-toolchain.toml" "${b}/clippy.toml" "${b}/deny.toml" \
    "${b}/typos.toml" "${work}/project/"
  cp "${b}/.config/nextest.toml" "${work}/project/.config/"
  {
    printf '[workspace]\nmembers = ["crates/*"]\n\n'
    cat "${b}/workspace-lints.toml"
  } >"${work}/project/Cargo.toml"
  (cd "${work}/project" && bash -c "${helpers}"$'\n'"$(cat)")
  out="$(cd "${work}/project" &&
    DRIFT_BASE_REF="${BASE_REF:-}" python3 -I "${work}/rust-ci/actions/baseline-drift/drift.py" 2>&1)"
  code=$?
  if [[ ${code} -ne ${want_code} ]] || [[ "${out}" != *"${want}"* ]] ||
    [[ -n "${unwanted}" && "${out}" == *"${unwanted}"* ]]; then
    echo "FAIL ${name}: exit ${code} (want ${want_code}), output:"
    printf '%s\n' "${out}" | sed 's/^/    /'
    failures=$((failures + 1))
  else
    echo "ok   ${name}"
  fi
}

# A member crate at crates/<name> with the given [lints] table (or none).
member='add_member() {
  mkdir -p "crates/$1" && printf "[package]\nname = \"%s\"\n%b" "$1" "$2" >"crates/$1/Cargo.toml"
}'
helpers+=$'\n'"${member}"

run_case "identical copies have no drift" 0 "no drift" "::" <<<":"
run_case "comments and order don't count" 0 "no drift" "::" \
  <<<"{ echo '# a comment'; tac rustfmt.toml | grep -v '^#'; } >x && mv x rustfmt.toml"

# Exact files: any difference in a value the project has is an error.
run_case "changed toolchain is an error" 1 '::error title=rust-ci baseline drift::rust-toolchain.toml: toolchain.channel is "1.97.0"' "no drift" \
  <<<"sed -i 's/channel = .*/channel = \"1.97.0\"/' rust-toolchain.toml"
run_case "changed rustfmt value is an error" 1 "::error title=rust-ci baseline drift::rustfmt.toml: max_width is 120" "no drift" \
  <<<"sed -i 's/max_width = 100/max_width = 120/' rustfmt.toml"
run_case "extra rustfmt key is an error" 1 "::error title=rust-ci baseline drift::rustfmt.toml: hard_tabs is not in the baseline" "no drift" \
  <<<"echo 'hard_tabs = true' >>rustfmt.toml"
run_case "missing rustfmt key is a warning" 0 "::warning title=rust-ci baseline drift::rustfmt.toml: use_try_shorthand is missing" "::error" \
  <<<"sed -i '/use_try_shorthand/d' rustfmt.toml"
run_case "missing file is a warning" 0 "::warning title=rust-ci baseline drift::.config/nextest.toml is missing" "::error" \
  <<<"rm .config/nextest.toml"

# Core files.
run_case "extra nextest profile is not drift" 0 "no drift" "::" \
  <<<"printf '\n[profile.slow]\nretries = 2\n' >>.config/nextest.toml"
run_case "changed nextest setting is an error" 1 "::error title=rust-ci baseline drift::.config/nextest.toml: profile.ci.fail-fast is true" "no drift" \
  <<<"sed -i 's/fail-fast = false/fail-fast = true/' .config/nextest.toml"
run_case "extra deny entries are not drift" 0 "no drift" "::" \
  <<<"sed -i 's/^allow = \[$/allow = [\n  \"MPL-2.0\",/' deny.toml && printf '\n[[licenses.exceptions]]\ncrate = \"x\"\nallow = [\"MPL-2.0\"]\n' >>deny.toml"
run_case "missing licence is a warning" 0 '::warning title=rust-ci baseline drift::deny.toml: licenses.allow lacks "ISC"' "::error" \
  <<<"sed -i '/\"ISC\",/d' deny.toml"
run_case "weakened deny severity is an error" 1 'deny.toml: bans.wildcards is "warn", weaker than the baseline'"'"'s "deny"' "no drift" \
  <<<"sed -i 's/^wildcards = \"deny\"/wildcards = \"warn\"/' deny.toml"
run_case "stricter deny severity is not drift" 0 "no drift" "::" \
  <<<"sed -i 's/^multiple-versions = \"warn\"/multiple-versions = \"deny\"/' deny.toml"
run_case "narrower unmaintained scope is an error" 1 'advisories.unmaintained is "none", weaker' "no drift" \
  <<<"sed -i 's/^unmaintained = .*/unmaintained = \"none\"/' deny.toml"
run_case "wider unmaintained scope is not drift" 0 "no drift" "::" \
  <<<"sed -i 's/^unmaintained = .*/unmaintained = \"all\"/' deny.toml"
run_case "other unmaintained scope is an error" 1 'advisories.unmaintained is "transitive", weaker' "no drift" \
  <<<"sed -i 's/^unmaintained = .*/unmaintained = \"transitive\"/' deny.toml"
run_case "lower confidence threshold is an error" 1 "licenses.confidence-threshold is 0.5, weaker" "no drift" \
  <<<"sed -i 's/^confidence-threshold = .*/confidence-threshold = 0.5/' deny.toml"
run_case "changed deny boolean is an error" 1 "deny.toml: graph.all-features is false (baseline: true)" "no drift" \
  <<<"sed -i 's/^all-features = true/all-features = false/' deny.toml"
run_case "extra typos words are not drift" 0 "no drift" "::" \
  <<<"printf 'nota = \"nota\"\n' >>typos.toml"
run_case "clippy.toml is compared" 1 "::error title=rust-ci baseline drift::clippy.toml: allow-panic-in-tests is \"no\" (baseline: true)" "no drift" \
  <<<"sed -i 's/^allow-panic-in-tests = .*/allow-panic-in-tests = \"no\"/' clippy.toml"
run_case "stricter clippy.toml switch is not drift" 0 "no drift" "::" \
  <<<"sed -i 's/^allow-panic-in-tests = .*/allow-panic-in-tests = false/' clippy.toml && echo 'msrv = \"1.98.1\"' >>clippy.toml"
run_case "missing clippy.toml is a warning" 0 "::warning title=rust-ci baseline drift::clippy.toml is missing" "::error" \
  <<<"rm clippy.toml"
run_case "unparsable file is an error" 1 "::error title=rust-ci baseline drift::could not read deny.toml" "no drift" \
  <<<"echo 'not = = toml' >>deny.toml"

# Lints in Cargo.toml.
run_case "extra lint is not drift" 0 "no drift" "::" \
  <<<"sed -i 's/^\[workspace.lints.clippy\]$/[workspace.lints.clippy]\nindexing_slicing = \"warn\"/' Cargo.toml"
run_case "extra allowed lint is an error" 1 'clippy.indexing_slicing is "allow", which turns lints off' "no drift" \
  <<<"sed -i 's/^\[workspace.lints.clippy\]$/[workspace.lints.clippy]\nindexing_slicing = \"allow\"/' Cargo.toml"
run_case "extra allowed group at a high priority is an error" 1 'clippy.restriction is {"level": "allow", "priority": 1}, which turns lints off' "no drift" \
  <<<"sed -i 's/^\[workspace.lints.clippy\]$/[workspace.lints.clippy]\nrestriction = { level = \"allow\", priority = 1 }/' Cargo.toml"
run_case "allowed warnings are an error" 1 'rust.warnings is {"level": "allow", "priority": 10}; `warnings` may only be deny or forbid' "no drift" \
  <<<"sed -i 's/^\[workspace.lints.rust\]$/[workspace.lints.rust]\nwarnings = { level = \"allow\", priority = 10 }/' Cargo.toml"
run_case "denied warnings are not drift" 0 "no drift" "::" \
  <<<"sed -i 's/^\[workspace.lints.rust\]$/[workspace.lints.rust]\nwarnings = \"deny\"/' Cargo.toml"
run_case "extra lint without a level is an error" 1 'clippy.indexing_slicing is {"priority": 1}, which is not a lint level' "no drift" \
  <<<"sed -i 's/^\[workspace.lints.clippy\]$/[workspace.lints.clippy]\nindexing_slicing = { priority = 1 }/' Cargo.toml"
run_case "weaker lint level is an error" 1 'rust.unsafe_code is "allow", weaker than the baseline'"'"'s "forbid"' "no drift" \
  <<<"sed -i 's/unsafe_code = \"forbid\"/unsafe_code = \"allow\"/' Cargo.toml"
run_case "stricter lint level is not drift" 0 "no drift" "::" \
  <<<"sed -i 's/^todo = \"warn\"/todo = \"deny\"/; s/^pedantic = .*/pedantic = { priority = -1, level = \"deny\" }/' Cargo.toml"
run_case "weaker lint group is an error" 1 'clippy.pedantic is {"level": "allow", "priority": -1}, weaker' "no drift" \
  <<<"sed -i 's/^pedantic = .*/pedantic = { level = \"allow\", priority = -1 }/' Cargo.toml"
run_case "changed lint priority is an error" 1 "clippy.pedantic has priority 0 (baseline: -1)" "no drift" \
  <<<"sed -i 's/^pedantic = .*/pedantic = \"warn\"/' Cargo.toml"
run_case "missing lint is a warning" 0 "::warning title=rust-ci baseline drift::Cargo.toml [workspace.lints]: clippy.use_self is missing" "::error" \
  <<<"sed -i '/^use_self/d' Cargo.toml"
run_case "Cargo.toml without lints is a warning" 0 "has no [workspace.lints]" "no drift" \
  <<<"printf '[workspace]\n' >Cargo.toml"

# Config files that replace the root's clippy.toml and rustfmt.toml.
run_case "root .clippy.toml is an error" 1 ".clippy.toml is read in place of clippy.toml" "no drift" \
  <<<"echo 'allow-panic-in-tests = false' >.clippy.toml"
run_case "root .rustfmt.toml is an error" 1 ".rustfmt.toml is read in place of rustfmt.toml" "no drift" \
  <<<"cp rustfmt.toml .rustfmt.toml"
run_case "member clippy.toml is an error" 1 "crates/a/clippy.toml replaces the root's clippy.toml under crates/a/" "no drift" \
  <<<"add_member a '[lints]\nworkspace = true\n' && touch crates/a/clippy.toml"
run_case "rustfmt.toml in a member's sources is an error" 1 "crates/a/src/x/.rustfmt.toml replaces the root's rustfmt.toml" "no drift" \
  <<<"add_member a '[lints]\nworkspace = true\n' && mkdir -p crates/a/src/x && touch crates/a/src/x/.rustfmt.toml"
run_case "clippy.toml above a member is an error" 1 "crates/clippy.toml replaces the root's clippy.toml under crates/" "no drift" \
  <<<"add_member a '[lints]\nworkspace = true\n' && touch crates/clippy.toml"
run_case "config files outside the members are not drift" 0 "no drift" "::" \
  <<<"add_member a '[lints]\nworkspace = true\n' && mkdir -p docs crates/a/target crates/a/vendored && touch docs/clippy.toml crates/a/target/rustfmt.toml crates/a/vendored/.git crates/a/vendored/rustfmt.toml"

# .cargo/config.toml.
run_case "capped lints in rustflags are an error" 1 '.cargo/config.toml: build.rustflags has "--cap-lints allow", which turns lints off' "no drift" \
  <<<"mkdir .cargo && printf '[build]\nrustflags = [\"--cap-lints\", \"allow\"]\n' >.cargo/config.toml"
run_case "allowed lints in target rustflags are an error" 1 'target.x86_64-unknown-linux-gnu.rustflags has "-Aclippy::all"' "no drift" \
  <<<"mkdir .cargo && printf '[target.x86_64-unknown-linux-gnu]\nrustflags = \"-C debuginfo=1 -Aclippy::all\"\n' >.cargo/config.toml"
run_case "alias over a CI command is an error" 1 '.cargo/config.toml: [alias] replaces `cargo clippy`' "no drift" \
  <<<"mkdir .cargo && printf '[alias]\nclippy = \"check\"\nxtask = \"run -p xtask --\"\n' >.cargo/config.toml"
run_case "legacy .cargo/config is checked" 1 '.cargo/config: [env] sets CLIPPY_ARGS' "no drift" \
  <<<"mkdir .cargo && printf '[env]\nCLIPPY_ARGS = \"-Aclippy::all\"\nMY_SETTING = \"1\"\n' >.cargo/config"
run_case "rustc wrapper is an error" 1 'build.rustc-wrapper is "./fake-rustc"' "no drift" \
  <<<"mkdir .cargo && printf '[build]\nrustc-wrapper = \"./fake-rustc\"\nwarnings = \"allow\"\n' >.cargo/config.toml"
run_case "allowed build warnings are an error" 1 'build.warnings is "allow"' "no drift" \
  <<<"mkdir .cargo && printf '[build]\nwarnings = \"allow\"\n' >.cargo/config.toml"
run_case "sccache and plain rustflags are not drift" 0 "no drift" "::" \
  <<<"mkdir .cargo && printf '[build]\nrustc-wrapper = \"/usr/bin/sccache\"\nrustflags = [\"-C\", \"target-cpu=native\", \"-Dwarnings\"]\n' >.cargo/config.toml"
run_case "test runner is a warning" 0 '::warning title=rust-ci baseline drift::.cargo/config.toml: target.x86_64-unknown-linux-gnu.runner runs the tests through "qemu"' "::error" \
  <<<"mkdir .cargo && printf '[target.x86_64-unknown-linux-gnu]\nrunner = \"qemu\"\n' >.cargo/config.toml"
run_case "unparsable cargo config is an error" 1 "could not read .cargo/config.toml" "no drift" \
  <<<"mkdir .cargo && echo 'not = = toml' >.cargo/config.toml"

# Removed since the base commit.
BASE_REF=HEAD run_case "base commit without changes is no drift" 0 "no drift" "::" \
  <<<"commit_base"
BASE_REF=HEAD run_case "lint removed since the base is an error" 1 "::error title=rust-ci baseline drift::Cargo.toml [workspace.lints]: clippy.use_self was removed" "no drift" \
  <<<"commit_base && sed -i '/^use_self/d' Cargo.toml"
BASE_REF=HEAD run_case "lint missing at the base too is a warning" 0 "clippy.use_self is missing" "::error" \
  <<<"sed -i '/^use_self/d' Cargo.toml && commit_base"
BASE_REF=HEAD run_case "list item removed since the base is an error" 1 'deny.toml: licenses.allow lost "ISC"' "no drift" \
  <<<"commit_base && sed -i '/\"ISC\",/d' deny.toml"
BASE_REF=HEAD run_case "file removed since the base is an error" 1 "::error title=rust-ci baseline drift::clippy.toml was removed" "no drift" \
  <<<"commit_base && rm clippy.toml"
BASE_REF=HEAD run_case "symlinked file at the base is read through the link" 1 "rustfmt.toml: use_try_shorthand was removed" "could not read" \
  <<<"mkdir b && mv rustfmt.toml b/ && ln -s b/rustfmt.toml rustfmt.toml && commit_base && sed -i '/use_try_shorthand/d' b/rustfmt.toml"
BASE_REF=0000000000000000000000000000000000000000 run_case "unknown base commit is an error" 1 "is not in the checkout" "no drift" \
  <<<"commit_base"

# Members take the workspace lints.
run_case "member with workspace lints is not drift" 0 "no drift" "::" \
  <<<"add_member a '[lints]\nworkspace = true\n'"
run_case "member without [lints] is an error" 1 "::error title=rust-ci baseline drift::crates/a/Cargo.toml has no [lints]" "no drift" \
  <<<"add_member a ''"
run_case "member overriding the lints is an error" 1 "crates/a/Cargo.toml [lints] sets its own lints" "no drift" \
  <<<"add_member a '[lints.rust]\nunsafe_code = \"allow\"\n'"
run_case "excluded member is not checked" 0 "no drift" "::" \
  <<<"add_member a '' && sed -i 's/^members = .*/&\nexclude = [\"crates\/a\"]/' Cargo.toml"
run_case "path dependency inside the workspace is a member" 1 "other/b/Cargo.toml has no [lints]" "no drift" \
  <<<"add_member a '[lints]\nworkspace = true\n[dependencies]\nb = { path = \"../../other/b\" }\n' && mkdir -p other/b && printf '[package]\nname = \"b\"\n' >other/b/Cargo.toml"
run_case "member under a ** glob is checked" 1 "crates/x/y/deep/Cargo.toml has no [lints]" "no drift" \
  <<<"sed -i 's|^members = .*|members = [\"crates/**/deep\"]|' Cargo.toml && mkdir -p crates/x/y/deep && printf '[package]\nname = \"deep\"\n' >crates/x/y/deep/Cargo.toml"
run_case "unused workspace path dependency is not a member" 0 "no drift" "::" \
  <<<"add_member a '[lints]\nworkspace = true\n' && mkdir -p other/b && printf '[package]\nname = \"b\"\n' >other/b/Cargo.toml && printf '\n[workspace.dependencies]\nb = { path = \"other/b\" }\n' >>Cargo.toml"
run_case "inherited workspace path dependency is a member" 1 "other/b/Cargo.toml has no [lints]" "no drift" \
  <<<"add_member a '[lints]\nworkspace = true\n[dependencies]\nb.workspace = true\n' && mkdir -p other/b && printf '[package]\nname = \"b\"\n' >other/b/Cargo.toml && printf '\n[workspace.dependencies]\nb = { path = \"other/b\" }\n' >>Cargo.toml"
run_case "root package without [lints] is an error" 1 "Cargo.toml has no [lints]" "no drift" \
  <<<"sed -i '1i [package]\nname = \"root\"\n' Cargo.toml"

if [[ ${failures} -ne 0 ]]; then
  echo "${failures} case(s) failed"
  exit 1
fi
echo "all drift cases passed"
