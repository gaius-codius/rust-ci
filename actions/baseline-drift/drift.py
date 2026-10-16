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
  baseline's level or a stricter one. A project may add lints.

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


def dependency_paths(manifest, directory):
    """The directories of a manifest's path dependencies, in every dependency table."""
    tables = [manifest.get(name, {}) for name in ("dependencies", "dev-dependencies", "build-dependencies")]
    for target in manifest.get("target", {}).values():
        if isinstance(target, dict):
            tables += [target.get(name, {}) for name in ("dependencies", "dev-dependencies", "build-dependencies")]
    for deps in tables:
        if not isinstance(deps, dict):
            continue
        for dep in deps.values():
            if isinstance(dep, dict) and isinstance(dep.get("path"), str):
                yield (directory / dep["path"]).resolve()


def check_members():
    """Every workspace member must take the workspace's lints.

    Members are the root package, if any, the `members` globs, and path
    dependencies inside the workspace (cargo makes those members too), less
    `exclude`.
    """
    try:
        manifest = tomllib.loads(Path("Cargo.toml").read_text())
    except (OSError, tomllib.TOMLDecodeError):
        return []  # reported by the lints comparison
    workspace = manifest.get("workspace")
    if not isinstance(workspace, dict):
        return []
    root = Path.cwd().resolve()
    excluded = [(root / path).resolve() for path in workspace.get("exclude", [])]
    queue = [root] if "package" in manifest else []
    for pattern in workspace.get("members", []):
        queue += [(root / match).resolve() for match in glob.glob(pattern, include_hidden=True)]
    queue += dependency_paths({"dependencies": workspace.get("dependencies", {})}, root)
    problems, seen = [], set()
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
        try:
            member = tomllib.loads((directory / "Cargo.toml").read_text())
        except (OSError, tomllib.TOMLDecodeError) as err:
            problems.append((ERROR, f"could not read {name}, so its lints were not checked: {err}"))
            continue
        queue += dependency_paths(member, directory)
        lints = member.get("lints")
        if lints is None:
            problems.append((ERROR, f"{name} has no [lints]; add `[lints] workspace = true`."))
        elif lints != {"workspace": True}:
            problems.append(
                (ERROR, f"{name} [lints] sets its own lints; it must hold only `workspace = true`.")
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
    problems += check_members()
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
