"""Compares the project in the current directory with the rust-ci baseline.

Prints a GitHub annotation for each difference, and exits 1 if any of them is
an error.

Errors (they fail the job):

- a setting the project has with a value weaker than the baseline's (see
  "Weaker" below);
- a baseline setting, list item or file that the project had at the base
  commit and no longer has. The base commit is DRIFT_BASE_REF (in CI, the
  pull request's base), read from git; without it nothing counts as removed;
- a workspace member whose Cargo.toml lacks `[lints] workspace = true`, or
  whose [lints] table sets lints of its own instead;
- a .clippy.toml or .rustfmt.toml at the root, or a clippy.toml,
  .clippy.toml, rustfmt.toml or .rustfmt.toml in or above a workspace
  member's directory: the tools read it in place of the root's file;
- a root .cargo/config.toml (or .cargo/config) that loosens what CI runs:
  rustflags or rustdocflags that allow or cap lints, `build.warnings =
  "allow"`, a rustc or rustdoc of its own or a rustc wrapper other than
  sccache, an [alias] for a command CI runs, or an [env] variable that CI's
  tools read. A test `runner` is a warning;
- a switch that takes tests or checks out of the run: `[lib] test = false` in
  a member, `overflow-checks` or `debug-assertions` off in the dev or test
  profile (in Cargo.toml or .cargo/config.toml), nextest retries above the
  baseline's in the ci profile or a profile it inherits (in another profile,
  more retries than at the base commit), and, new since the base commit,
  `autotests = false` or a nextest `default-filter`. Without a base commit
  those two are warnings, as are `[lib] doctest = false` and a [[test]] with
  `test = false` or `harness = false`;
- an entry in `workspace.exclude` or deny.toml's `advisories.ignore`,
  `bans.skip` or `bans.skip-tree` that the base commit didn't have. Entries
  the base had, and every entry when there is no base, pass;
- a file that can't be read or parsed, or a check that could not run.

Warnings: a baseline setting, list item or file the project doesn't have and
didn't have at the base commit. This is how a new baseline item reaches
projects that haven't copied it yet.

Three kinds of comparison:

- exact: the project's file holds the same settings as the baseline, no more
  and no fewer (rustfmt.toml, rust-toolchain.toml). A different value or an
  extra setting is an error: a different toolchain is drift the project must
  fix, and these files are copied as they are;
- core: every setting in the baseline is in the project's file with the same
  value or a stricter one, and lists hold at least the baseline's items. A
  project may add its own settings and list items (.config/nextest.toml,
  clippy.toml, deny.toml, typos.toml);
- lints: the [workspace.lints] tables in Cargo.toml, each lint at the
  baseline's level or a stricter one. A project may add lints at `warn` or
  stricter; an extra `allow` (of a lint or a group, at any priority) and a
  `warnings` entry other than deny or forbid are errors.

Weaker, where values can be ordered:

- lint levels: allow < warn < deny < forbid. A `{ level, priority }` table
  compares by level, and its priority must equal the baseline's (0 when not
  given), since there is no order in which a priority is safely different;
- deny.toml severities (allow < warn < deny), and the scopes of
  `advisories.unmaintained` and `advisories.unsound`, where "all" covers both
  "workspace" and "transitive", and "none" covers neither. A scope that
  covers what the baseline's covers is not weaker;
- deny.toml `licenses.confidence-threshold`: a higher one is stricter;
- clippy.toml `allow-*` switches: false is stricter than true.

Any other value the project has that differs from the baseline's is an error.

Comments and formatting are not compared. Needs Python 3.11 or later (tomllib)
and, with DRIFT_BASE_REF set, git.
"""

import glob
import json
import os
import subprocess
import sys
import tomllib
from pathlib import Path

BASELINE = Path(__file__).resolve().parent.parent.parent / "baseline"

# (project file, baseline file, kind, table inside the project file or None)
FILES = [
    ("rustfmt.toml", "rustfmt.toml", "exact", None),
    ("rust-toolchain.toml", "rust-toolchain.toml", "exact", None),
    (".config/nextest.toml", ".config/nextest.toml", "core", None),
    ("clippy.toml", "clippy.toml", "core", None),
    ("deny.toml", "deny.toml", "core", None),
    ("typos.toml", "typos.toml", "core", None),
    ("Cargo.toml", "workspace-lints.toml", "lints", "workspace.lints"),
]

LEVELS = {"allow": 0, "warn": 1, "deny": 2, "forbid": 3}
# Which crates a cargo-deny unmaintained or unsound check applies to.
SCOPES = {
    "none": set(),
    "workspace": {"workspace"},
    "transitive": {"transitive"},
    "all": {"workspace", "transitive"},
}
SCOPED = {"advisories.unmaintained", "advisories.unsound"}

ERROR, WARNING = "error", "warning"


def show(value):
    return json.dumps(value, sort_keys=True)


def flatten(data, prefix=""):
    """Maps each setting's dotted path to its value; tables are walked into."""
    out = {}
    for key, value in data.items():
        path = f"{prefix}{key}"
        if isinstance(value, dict) and value:
            out.update(flatten(value, path + "."))
        else:
            out[path] = value
    return out


def flatten_lints(data):
    """Maps each lint's `tool.name` to its level, a string or a table."""
    return {
        f"{tool}.{name}": value
        for tool, lints in data.items()
        if isinstance(lints, dict)
        for name, value in lints.items()
    }


def table(data, dotted):
    for part in dotted.split("."):
        data = data.get(part, {}) if isinstance(data, dict) else {}
    return data


def lint_level(value):
    """A lint's (level, priority)."""
    if isinstance(value, dict):
        return value.get("level"), value.get("priority", 0)
    return value, 0


def weakened(baseline_file, kind, path, want, have):
    """Why the project's value is drift, or None if it's the baseline's or stricter."""
    if type(want) is type(have) and want == have:
        return None
    differs = f"{path} is {show(have)} (baseline: {show(want)})"
    weaker = f"{path} is {show(have)}, weaker than the baseline's {show(want)}"
    if kind == "lints":
        (want_level, want_priority), (have_level, have_priority) = lint_level(want), lint_level(have)
        if want_level not in LEVELS or have_level not in LEVELS:
            return differs
        if LEVELS[have_level] < LEVELS[want_level]:
            return weaker
        if have_priority != want_priority:
            return f"{path} has priority {show(have_priority)} (baseline: {show(want_priority)})"
        return None
    if kind == "exact":
        return differs
    both_str = isinstance(want, str) and isinstance(have, str)
    if baseline_file == "deny.toml" and both_str and path in SCOPED:
        if want in SCOPES and have in SCOPES:
            return None if SCOPES[have] >= SCOPES[want] else weaker
    elif baseline_file == "deny.toml" and both_str:
        if want in LEVELS and have in LEVELS:
            return None if LEVELS[have] >= LEVELS[want] else weaker
    elif baseline_file == "deny.toml" and path == "licenses.confidence-threshold":
        numbers = all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in (want, have))
        if numbers:
            return None if have >= want else weaker
    elif baseline_file == "clippy.toml" and path.startswith("allow-"):
        if want is True and have is False:
            return None
    return differs


def compare(want, have, base, kind, baseline_file):
    """Returns (level, message) for each difference between two flattened files.

    base is the project's file at the base commit, flattened, or {}.
    """
    problems = []
    for path, value in want.items():
        if value == {} and any(k.startswith(path + ".") for k in have):
            continue  # an empty baseline table the project has filled in
        if path not in have:
            if path in base:
                problems.append((ERROR, f"{path} was removed (baseline: {show(value)})"))
            else:
                problems.append((WARNING, f"{path} is missing (baseline: {show(value)})"))
        elif isinstance(value, list) and kind != "exact" and isinstance(have[path], list):
            got = {show(item) for item in have[path]}
            had = base.get(path)
            had = {show(item) for item in had} if isinstance(had, list) else set()
            missing = [show(item) for item in value if show(item) not in got]
            removed = [item for item in missing if item in had]
            if removed:
                problems.append((ERROR, f"{path} lost {', '.join(removed)}"))
            if lacking := [item for item in missing if item not in had]:
                problems.append((WARNING, f"{path} lacks {', '.join(lacking)}"))
        elif why := weakened(baseline_file, kind, path, value, have[path]):
            problems.append((ERROR, why))
    if kind == "exact":
        for path in have.keys() - want.keys():
            problems.append((ERROR, f"{path} is not in the baseline"))
    if kind == "lints":
        problems += extra_lints({path: have[path] for path in have.keys() - want.keys()})
    return problems


def extra_lints(extra):
    """The project's own lints may be stricter, never `allow`.

    An extra `allow`, of one lint or a group, turns off lints the baseline
    turns on, at any priority. `warn` and stricter are fine: CI denies
    warnings. `warnings` itself must be deny or forbid.
    """
    problems = []
    for path, value in sorted(extra.items()):
        level, _ = lint_level(value)
        if level not in LEVELS:
            problems.append((ERROR, f"{path} is {show(value)}, which is not a lint level"))
        elif path.endswith(".warnings") and level not in ("deny", "forbid"):
            problems.append((ERROR, f"{path} is {show(value)}; `warnings` may only be deny or forbid"))
        elif level == "allow":
            problems.append(
                (
                    ERROR,
                    f"{path} is {show(value)}, which turns lints off; remove it, and put "
                    '#[expect(..., reason = "...")] where the lint fires instead',
                )
            )
    return problems


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, check=True).stdout


def read_at(ref, path):
    """The file's text at commit ref, following symlinks, or None if it's absent."""
    for _ in range(40):
        entry = git("ls-tree", "-z", ref, "--", path).rstrip(b"\0")
        if not entry:
            return None
        meta = entry.split(b"\t", 1)[0].split()
        mode, kind, oid = (part.decode() for part in meta)
        if kind != "blob":
            return None
        content = git("cat-file", "blob", oid)
        if mode != "120000":
            return content.decode()
        path = os.path.normpath(os.path.join(os.path.dirname(path), content.decode()))
    raise OSError(f"too many symlinks at {path}")


def check(project_file, baseline_file, kind, inner, ref):
    """Returns (level, message) for each difference in one file."""
    flat = flatten_lints if kind == "lints" else flatten
    where = f"{project_file} [{inner}]" if inner else project_file
    try:
        want = tomllib.loads((BASELINE / baseline_file).read_text())
        base_text = read_at(ref, project_file) if ref else None
        base = tomllib.loads(base_text) if base_text is not None else {}
    except (OSError, subprocess.CalledProcessError, tomllib.TOMLDecodeError) as err:
        return [(ERROR, f"could not read the baseline or base commit's {project_file}, so it was not compared: {err}")]
    if inner:
        want, base = table(want, inner), table(base, inner)
    project = Path(project_file)
    if not project.is_file():
        level = ERROR if base_text is not None else WARNING
        verb = "was removed" if level == ERROR else "is missing"
        return [(level, f"{project_file} {verb}; copy baseline/{baseline_file} from rust-ci.")]
    try:
        have = tomllib.loads(project.read_text())
    except (OSError, tomllib.TOMLDecodeError) as err:
        return [(ERROR, f"could not read {project_file}, so it was not compared: {err}")]
    if inner:
        have = table(have, inner)
        if not have:
            level = ERROR if base else WARNING
            verb = "lost" if level == ERROR else "has no"
            return [(level, f"{project_file} {verb} [{inner}]; copy it from rust-ci baseline/{baseline_file}.")]
    problems = compare(flat(want), flat(have), flat(base), kind, baseline_file)
    return [(level, f"{where}: {message}.") for level, message in problems]


def dependency_paths(manifest, directory, inherited):
    """The directories of a manifest's path dependencies, in every dependency table.

    inherited maps each [workspace.dependencies] entry with a path to its
    directory, for a dependency that takes it with `workspace = true`.
    """
    tables = [manifest.get(name, {}) for name in ("dependencies", "dev-dependencies", "build-dependencies")]
    for target in manifest.get("target", {}).values():
        if isinstance(target, dict):
            tables += [target.get(name, {}) for name in ("dependencies", "dev-dependencies", "build-dependencies")]
    for deps in tables:
        if not isinstance(deps, dict):
            continue
        for name, dep in deps.items():
            if not isinstance(dep, dict):
                continue
            if isinstance(dep.get("path"), str):
                yield (directory / dep["path"]).resolve()
            elif dep.get("workspace") is True and name in inherited:
                yield inherited[name]


def workspace_members():
    """The root manifest, its workspace members and any problems reading them.

    Members are (directory, Cargo.toml relative to the root, manifest): the
    root package, if any, the `members` globs, and the path dependencies of
    members that are inside the workspace (cargo makes those members too), less
    `exclude`. A [workspace.dependencies] path is a member only once a member
    uses it. Without a [workspace], the root package is the only member.
    """
    try:
        manifest = tomllib.loads(Path("Cargo.toml").read_text())
    except (OSError, tomllib.TOMLDecodeError):
        return None, [], []  # reported by the lints comparison
    root = Path.cwd().resolve()
    workspace = manifest.get("workspace")
    if not isinstance(workspace, dict):
        return manifest, ([(root, Path("Cargo.toml"), manifest)] if "package" in manifest else []), []
    excluded = [(root / path).resolve() for path in workspace.get("exclude", [])]
    inherited = {
        name: (root / dep["path"]).resolve()
        for name, dep in workspace.get("dependencies", {}).items()
        if isinstance(dep, dict) and isinstance(dep.get("path"), str)
    }
    queue = [root] if "package" in manifest else []
    for pattern in workspace.get("members", []):
        queue += [(root / match).resolve() for match in glob.glob(pattern, recursive=True, include_hidden=True)]
    members, problems, seen = [], [], set()
    while queue:
        directory = queue.pop()
        if (
            directory in seen
            or not directory.is_relative_to(root)
            or any(directory.is_relative_to(path) for path in excluded)
            or not (directory / "Cargo.toml").is_file()
        ):
            continue
        seen.add(directory)
        name = (directory / "Cargo.toml").relative_to(root)
        if directory == root:
            member = manifest
        else:
            try:
                member = tomllib.loads((directory / "Cargo.toml").read_text())
            except (OSError, tomllib.TOMLDecodeError) as err:
                problems.append((ERROR, f"could not read {name}, so it was not checked: {err}"))
                continue
        queue += dependency_paths(member, directory, inherited)
        members.append((directory, name, member))
    return manifest, members, problems


def check_members(manifest, members):
    """Every workspace member must take the workspace's lints."""
    if not isinstance(manifest, dict) or not isinstance(manifest.get("workspace"), dict):
        return []
    problems = []
    for _, name, member in members:
        lints = member.get("lints")
        if lints is None:
            problems.append((ERROR, f"{name} has no [lints]; add `[lints] workspace = true`."))
        elif lints != {"workspace": True}:
            problems.append(
                (ERROR, f"{name} [lints] sets its own lints; it must hold only `workspace = true`.")
            )
    return problems


def load(path):
    """The project's file, parsed, or None if it's absent or unparsable (reported elsewhere)."""
    try:
        return tomllib.loads(Path(path).read_text())
    except (OSError, tomllib.TOMLDecodeError):
        return None


def at_base(ref, path):
    """The file at the base commit, parsed, or {} if the base hasn't got it."""
    text = read_at(ref, path)
    return tomllib.loads(text) if text is not None else {}


BASE_ERRORS = (OSError, subprocess.CalledProcessError, tomllib.TOMLDecodeError)


def check_test_switches(members, ref):
    """Settings in a member's Cargo.toml that take tests out of the test run."""
    problems = []
    for _, name, member in members:
        lib = member.get("lib", {})
        if isinstance(lib, dict) and lib.get("test") is False:
            problems.append(
                (ERROR, f"{name}: [lib] test = false leaves the library's unit tests out of the test run; remove it.")
            )
        if isinstance(lib, dict) and lib.get("doctest") is False:
            problems.append(
                (WARNING, f"{name}: [lib] doctest = false skips the library's doctests; remove it unless it has none.")
            )
        if table(member, "package").get("autotests") is False:
            skips = "[package] autotests = false leaves files in tests/ without a [[test]] entry out of the test run"
            try:
                base = at_base(ref, name.as_posix()) if ref else {}
            except BASE_ERRORS as err:
                problems.append((ERROR, f"could not read the base commit's {name}, so its autotests were not compared: {err}"))
                continue
            if ref and table(base, "package").get("autotests") is not False:
                problems.append(
                    (ERROR, f"{name}: {skips}, and is new since the base commit; it needs the code owner's approval: explain it in the pull request.")
                )
            else:
                problems.append((WARNING, f"{name}: {skips}; check that each has an entry."))
        tests = member.get("test", [])
        for test in tests if isinstance(tests, list) else []:
            if not isinstance(test, dict):
                continue
            target = f"[[test]] {show(test.get('name'))}"
            if test.get("test") is False:
                problems.append((WARNING, f"{name}: {target} has test = false, so the test run skips it."))
            if test.get("harness") is False:
                problems.append(
                    (WARNING, f"{name}: {target} has harness = false; check that its main fails when a test fails.")
                )
    return problems


def check_profiles(config, where):
    """The dev and test profiles, which tests build with, must keep their runtime checks."""
    problems = []
    for profile in ("dev", "test"):
        settings = table(config, f"profile.{profile}")
        if not isinstance(settings, dict):
            continue
        scopes = [(f"profile.{profile}", settings), (f"profile.{profile}.build-override", settings.get("build-override"))]
        packages = settings.get("package", {})
        if isinstance(packages, dict):
            scopes += [(f"profile.{profile}.package.{show(crate)}", value) for crate, value in packages.items()]
        for scope, values in scopes:
            if not isinstance(values, dict):
                continue
            for key in ("overflow-checks", "debug-assertions"):
                if values.get(key) is False:
                    problems.append(
                        (ERROR, f"{where}: {scope}.{key} is false, which turns off checks the tests rely on; remove it.")
                    )
    return problems


def retries(value):
    """A nextest retries setting's count: a number or a table with `count`."""
    if isinstance(value, dict):
        value = value.get("count", 0)
    return value if isinstance(value, int) and not isinstance(value, bool) else 0


def profile_retries(config, name):
    """The most retries a nextest profile sets, itself or in an override."""
    profile = table(config, f"profile.{name}")
    counts = [retries(profile.get("retries"))] if isinstance(profile, dict) else [0]
    overrides = profile.get("overrides", []) if isinstance(profile, dict) else []
    counts += [retries(o.get("retries")) for o in overrides if isinstance(o, dict)] if isinstance(overrides, list) else []
    return max(counts)


def inherited_profiles(config, name):
    """A nextest profile and the profiles it inherits from, ending with default."""
    names = []
    while isinstance(name, str) and name not in names:
        names.append(name)
        profile = table(config, f"profile.{name}")
        name = profile.get("inherits") if isinstance(profile, dict) and name != "default" else None
    return names if "default" in names else [*names, "default"]


def check_nextest(ref):
    """nextest must not retry tests in CI's profiles, or filter tests out unseen.

    Retries make a flaky test pass. The ci profile and every profile it
    inherits from may retry no more than the baseline's; another profile may
    keep the retries it had at the base commit. A default-filter leaves tests
    out of every run.
    """
    name = ".config/nextest.toml"
    have = load(name)
    if have is None:
        return []
    try:
        want = tomllib.loads((BASELINE / name).read_text())
        base = at_base(ref, name) if ref else {}
    except BASE_ERRORS as err:
        return [(ERROR, f"could not read the baseline or base commit's {name}, so its retries were not checked: {err}")]
    profiles = table(have, "profile")
    profiles = list(profiles) if isinstance(profiles, dict) else []
    ci = inherited_profiles(have, "ci")
    problems = []
    for profile in sorted({*profiles, "default"}):
        count, limit = profile_retries(have, profile), profile_retries(want, profile)
        had = profile_retries(base, profile)
        if count > limit and (profile in ci or (ref and count > had)):
            why = "the ci profile uses it" if profile in ci else "it has more than at the base commit"
            problems.append(
                (ERROR, f"{name}: profile.{profile} retries tests {count} times (baseline: {limit}), and {why}; a retried test that passes counts as passed, so flaky tests go unseen. Remove the retries.")
            )
        settings = table(have, f"profile.{profile}")
        if isinstance(settings, dict) and "default-filter" in settings:
            value = settings["default-filter"]
            skips = f"profile.{profile}.default-filter is {show(value)}, which leaves the tests it doesn't match out of every run"
            if ref and table(base, f"profile.{profile}").get("default-filter") != value:
                problems.append(
                    (ERROR, f"{name}: {skips}; a new or changed filter needs the code owner's approval: explain it in the pull request.")
                )
            else:
                problems.append((WARNING, f"{name}: {skips}."))
    return problems


# Lists whose entries turn a check off for some crates or advisories: (file,
# setting, what an entry is).
EXCEPTION_LISTS = [
    ("Cargo.toml", "workspace.exclude", "workspace exclude"),
    ("deny.toml", "advisories.ignore", "advisory ignore"),
    ("deny.toml", "bans.skip", "duplicate-version skip"),
    ("deny.toml", "bans.skip-tree", "duplicate-version skip"),
]


def entry_key(entry):
    """An exception list entry, less its reason, which may be reworded."""
    if isinstance(entry, dict):
        entry = {key: value for key, value in entry.items() if key != "reason"}
    return show(entry)


def check_new_exceptions(ref):
    """An exception the base commit didn't have is an error; ones it had are the base's call.

    Without a base commit (a push), nothing is new.
    """
    if not ref:
        return []
    problems = []
    for name, setting, what in EXCEPTION_LISTS:
        have = load(name)
        if have is None:
            continue
        try:
            base = at_base(ref, name)
        except BASE_ERRORS as err:
            problems.append((ERROR, f"could not read the base commit's {name}, so new {what}s were not checked: {err}"))
            continue
        entries, had = table(have, setting), table(base, setting)
        if not isinstance(entries, list):
            continue
        had = {entry_key(entry) for entry in had} if isinstance(had, list) else set()
        if new := [entry_key(entry) for entry in entries if entry_key(entry) not in had]:
            problems.append(
                (ERROR, f"{name}: {setting} has {', '.join(new)}, new since the base commit; a new {what} needs the code owner's approval: explain it in the pull request.")
            )
    return problems


# Each tool's config file names, the one it reads first leading: a .clippy.toml
# or .rustfmt.toml wins over the plain name in the same directory.
TOOL_CONFIGS = {"clippy.toml": (".clippy.toml", "clippy.toml"), "rustfmt.toml": (".rustfmt.toml", "rustfmt.toml")}
# Directories never searched for config files: build output and git data.
SKIPPED_DIRECTORIES = {"target", ".git"}


def check_tool_configs(members):
    """clippy and rustfmt must read the root's clippy.toml and rustfmt.toml.

    Both tools take the first config file they find, searching from a crate's
    (clippy) or a source file's (rustfmt) directory up, and read .clippy.toml
    and .rustfmt.toml before the plain names. So a dotted file at the root, or
    either name in a member's directory, one of its subdirectories or a
    directory between it and the root, replaces the file the drift check
    compares.
    """
    root = Path.cwd().resolve()
    problems, directories = [], {root}
    for directory, _, _ in members:
        directories.update(parent for parent in [directory, *directory.parents] if parent.is_relative_to(root))
        for top, subdirectories, files in os.walk(directory):
            # A directory with a .git of its own is another checkout, not this one.
            subdirectories[:] = [
                name
                for name in subdirectories
                if name not in SKIPPED_DIRECTORIES and not (Path(top) / name / ".git").exists()
            ]
            directories.add(Path(top))
    for directory in sorted(directories):
        for compared, names in TOOL_CONFIGS.items():
            for name in names:
                path = directory / name
                if not path.is_file() or (directory == root and name == compared):
                    continue
                where = path.relative_to(root)
                if directory == root:
                    why = f"{where} is read in place of {compared}, which the drift check compares"
                else:
                    why = f"{where} replaces the root's {compared} under {directory.relative_to(root)}/"
                problems.append((ERROR, f"{why}; remove it, and keep its settings in the root's {compared}."))
    return problems


# Cargo commands CI runs, which an [alias] in .cargo/config.toml could replace.
CI_COMMANDS = {"clippy", "check", "build", "test", "nextest", "deny", "shear", "mutants", "fmt", "doc", "run"}
# Variables that change how CI's tools build, lint or test, which [env] would
# set for every process cargo starts.
CI_VARIABLES = {
    "RUSTFLAGS",
    "RUSTDOCFLAGS",
    "CARGO_ENCODED_RUSTFLAGS",
    "CARGO_ENCODED_RUSTDOCFLAGS",
    "CARGO_BUILD_RUSTFLAGS",
    "CARGO_BUILD_RUSTDOCFLAGS",
    "CARGO_BUILD_WARNINGS",
    "CLIPPY_CONF_DIR",
    "CLIPPY_ARGS",
    "RUSTC",
    "RUSTC_WRAPPER",
    "RUSTC_WORKSPACE_WRAPPER",
}


def weakening_flags(flags):
    """The rustc flags that turn lints off or cap them."""
    if isinstance(flags, str):
        flags = flags.split()
    if not isinstance(flags, list):
        return []
    flags = [str(flag) for flag in flags]
    found = []
    for i, flag in enumerate(flags):
        if flag in ("-A", "--allow", "--cap-lints"):
            found.append(" ".join(flags[i : i + 2]))
        elif flag.startswith(("-A", "--allow=", "--cap-lints=")):
            found.append(flag)
    return found


def check_cargo_config():
    """The root .cargo/config.toml must not loosen what CI runs.

    It can cap or allow lints through rustflags, replace a command CI runs
    with an alias, set variables the tools read, or put a wrapper around rustc.
    """
    problems = []
    for name in (".cargo/config.toml", ".cargo/config"):
        path = Path(name)
        if not path.is_file():
            continue
        try:
            config = tomllib.loads(path.read_text())
        except (OSError, tomllib.TOMLDecodeError) as err:
            problems.append((ERROR, f"could not read {name}, so it was not checked: {err}"))
            continue
        sections = [("build", config.get("build", {}))]
        targets = config.get("target", {})
        if isinstance(targets, dict):
            sections += [(f"target.{triple}", target) for triple, target in targets.items()]
        for section, settings in sections:
            if not isinstance(settings, dict):
                continue
            for key in ("rustflags", "rustdocflags"):
                for flag in weakening_flags(settings.get(key)):
                    problems.append(
                        (ERROR, f"{name}: {section}.{key} has {show(flag)}, which turns lints off; remove it.")
                    )
            if isinstance(settings.get("runner"), (str, list)):
                runner = show(settings["runner"])
                problems.append(
                    (WARNING, f"{name}: {section}.runner runs the tests through {runner}; check it passes on their result.")
                )
        problems += check_profiles(config, name)
        build = config.get("build", {})
        if isinstance(build, dict):
            if build.get("warnings") == "allow":
                problems.append((ERROR, f'{name}: build.warnings is "allow"; remove it.'))
            for key in ("rustc", "rustdoc", "rustc-wrapper", "rustc-workspace-wrapper"):
                value = build.get(key)
                if value in (None, ""):
                    continue
                stem = Path(str(value)).name.removesuffix(".exe")
                if key.endswith("wrapper") and stem == "sccache":
                    continue
                problems.append(
                    (ERROR, f"{name}: build.{key} is {show(value)}, which CI's results would come from; remove it.")
                )
        aliases = config.get("alias", {})
        if isinstance(aliases, dict):
            for alias in sorted(aliases.keys() & CI_COMMANDS):
                problems.append(
                    (ERROR, f"{name}: [alias] replaces `cargo {alias}`, which CI runs; remove or rename the alias.")
                )
        env = config.get("env", {})
        if isinstance(env, dict):
            for variable in sorted(env):
                if variable in CI_VARIABLES or variable.startswith("NEXTEST_"):
                    problems.append(
                        (ERROR, f"{name}: [env] sets {variable}, which changes how CI builds, lints or tests; remove it.")
                    )
    return problems


def main():
    problems = []
    ref = os.environ.get("DRIFT_BASE_REF", "").strip() or None
    if ref:
        try:
            git("rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}")
        except (OSError, subprocess.CalledProcessError):
            problems.append(
                (ERROR, f"the base commit {ref} is not in the checkout, so removals were not checked.")
            )
            ref = None
    for entry in FILES:
        problems += check(*entry, ref)
    manifest, members, problems_reading = workspace_members()
    problems += problems_reading
    problems += check_members(manifest, members)
    problems += check_tool_configs(members)
    problems += check_cargo_config()
    problems += check_test_switches(members, ref)
    if isinstance(manifest, dict):
        problems += check_profiles(manifest, "Cargo.toml")
    problems += check_nextest(ref)
    problems += check_new_exceptions(ref)
    for level, message in sorted(problems, key=lambda p: (p[0] != ERROR, p[1])):
        print(f"::{level} title=rust-ci baseline drift::{message}")
    if not problems:
        print("rust-ci baseline: no drift.")
    return 1 if any(level == ERROR for level, _ in problems) else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as err:  # a check that can't run must not pass
        print(f"::error title=rust-ci baseline drift::the drift check itself failed: {err!r}")
        sys.exit(1)
