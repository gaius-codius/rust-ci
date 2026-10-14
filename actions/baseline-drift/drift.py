"""Compares the project in the current directory with the rust-ci baseline.

Prints a GitHub warning for each difference, or for a comparison that could
not run. It only warns: the exit status is always 0.

Two kinds of comparison:

- exact: the project's file holds the same settings as the baseline, no more
  and no fewer (rustfmt.toml, rust-toolchain.toml);
- core: every setting in the baseline is in the project's file with the same
  value, and lists hold at least the baseline's items. A project may add its
  own settings and list items (.config/nextest.toml, deny.toml, typos.toml,
  and the [workspace.lints] tables in Cargo.toml).

Comments and formatting are not compared. Needs Python 3.11 or later (tomllib).
"""

import json
import sys
import tomllib
from pathlib import Path

BASELINE = Path(__file__).resolve().parent.parent.parent / "baseline"

# (project file, baseline file, kind, table inside the project file or None)
FILES = [
    ("rustfmt.toml", "rustfmt.toml", "exact", None),
    ("rust-toolchain.toml", "rust-toolchain.toml", "exact", None),
    (".config/nextest.toml", ".config/nextest.toml", "core", None),
    ("deny.toml", "deny.toml", "core", None),
    ("typos.toml", "typos.toml", "core", None),
    ("Cargo.toml", "workspace-lints.toml", "core", "workspace.lints"),
]


def warn(message):
    print(f"::warning title=rust-ci baseline drift::{message}")


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


def table(data, dotted):
    for part in dotted.split("."):
        data = data.get(part, {}) if isinstance(data, dict) else {}
    return data


def compare(want, have, kind):
    """Returns one line per difference between two flattened files."""
    problems = []
    for path, value in want.items():
        if value == {} and any(k.startswith(path + ".") for k in have):
            continue  # an empty baseline table the project has filled in
        if path not in have:
            problems.append(f"{path} is missing (baseline: {show(value)})")
        elif isinstance(value, list) and kind == "core" and isinstance(have[path], list):
            got = {show(item) for item in have[path]}
            missing = [show(item) for item in value if show(item) not in got]
            if missing:
                problems.append(f"{path} lacks {', '.join(missing)}")
        elif have[path] != value:
            problems.append(f"{path} is {show(have[path])} (baseline: {show(value)})")
    if kind == "exact":
        for path in have.keys() - want.keys():
            problems.append(f"{path} is not in the baseline")
    return problems


def check(project_file, baseline_file, kind, inner):
    project = Path(project_file)
    if not project.is_file():
        warn(f"{project_file} is missing; copy baseline/{baseline_file} from rust-ci.")
        return True
    try:
        want = tomllib.loads((BASELINE / baseline_file).read_text())
        have = tomllib.loads(project.read_text())
    except (OSError, tomllib.TOMLDecodeError) as err:
        warn(f"could not read {project_file} or its baseline, so it was not compared: {err}")
        return True
    if inner:
        want, have = table(want, inner), table(have, inner)
        if not have:
            warn(f"{project_file} has no [{inner}]; copy it from rust-ci baseline/{baseline_file}.")
            return True
    problems = compare(flatten(want), flatten(have), kind)
    for problem in sorted(problems):
        where = f"{project_file} [{inner}]" if inner else project_file
        warn(f"{where}: {problem}.")
    return bool(problems)


def main():
    drift = False
    for entry in FILES:
        drift |= check(*entry)
    if not drift:
        print("rust-ci baseline: no drift.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as err:  # warn-only: never fail the job
        warn(f"the drift check itself failed, so drift was not checked: {err!r}")
        sys.exit(0)
