"""Lists the crates a pull request adds to Cargo.lock.

Compares Cargo.lock at a base commit (the first argument) with Cargo.lock in
the current directory. Each package that is new prints a GitHub annotation:

- a warning for a crate the base didn't have from that source (a new
  dependency, or a known crate from a new registry or git repository);
- a notice for a new version of a crate the base already had from the same
  source (an update, or a second version next to the old one).

A git source is compared without its resolved commit (the "#<sha>"), so a git
dependency moved to a new commit of the same version isn't reported.

Packages without a source (workspace members and path dependencies) are left
out: they are in the repository, so the pull request's diff shows them. The
same list goes to the job summary ($GITHUB_STEP_SUMMARY) as a table.

It only reports, for a person to review: the exit status is always 0. Needs
git, and Python 3.11 or later (tomllib).
"""

import os
import subprocess
import sys
import tomllib
from pathlib import Path

TITLE = "New dependency"


def annotate(level, message):
    # A workflow command's message escapes these three; a git URL can hold %.
    message = message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    print(f"::{level} title={TITLE}::{message}")


def source_id(source):
    """The source a package comes from, less a git source's resolved commit.

    "git+https://host/repo?branch=main#<sha>" at another <sha> is the same
    repository, so moving a git dependency to a new commit isn't a new crate.
    The query (?branch=, ?rev=) stays: it names what is followed.
    """
    if source.startswith("git+"):
        return source.split("#", 1)[0]
    return source


def packages(text):
    """Maps (name, source) to the set of versions locked from that source."""
    out = {}
    for package in tomllib.loads(text).get("package", []):
        source = package.get("source")
        if source is None:
            continue
        key = (package["name"], source_id(source))
        out.setdefault(key, set()).add(package["version"])
    return out


def base_lock(base):
    """Cargo.lock's text at the base commit; empty if it had none."""
    result = subprocess.run(
        ["git", "show", f"{base}:Cargo.lock"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode == 0:
        return result.stdout
    exists = subprocess.run(
        ["git", "cat-file", "-e", f"{base}^{{commit}}"],
        capture_output=True,
        check=False,
    )
    if exists.returncode == 0:
        return ""
    raise LookupError(f"commit {base} is not in the checkout (fetch it first)")


def short_source(source):
    """The source without the "registry+" or "git+" prefix and a git commit."""
    kind, _, rest = source.partition("+")
    if kind == "git":
        rest = rest.split("#", 1)[0]
    return rest or source


def compare(base_text, head_text):
    """Returns (level, name, version, source) for each new package, sorted."""
    base = packages(base_text)
    head = packages(head_text)
    found = []
    for (name, source), versions in head.items():
        old = base.get((name, source))
        level = "warning" if old is None else "notice"
        for version in sorted(versions - (old or set())):
            found.append((level, name, version, source))
    found.sort(key=lambda row: (row[0] != "warning", row[1], row[2]))
    return found


def summary(rows, base):
    lines = [f"### New dependencies against {base[:12]}", ""]
    if not rows:
        lines.append("Cargo.lock adds no crates.")
    else:
        lines += [
            "| Crate | Version | Source | Kind |",
            "|---|---|---|---|",
        ]
        for level, name, version, source in rows:
            kind = "new crate" if level == "warning" else "new version"
            lines.append(f"| `{name}` | {version} | {short_source(source)} | {kind} |")
    return "\n".join(lines) + "\n"


def main():
    if len(sys.argv) != 2 or not sys.argv[1]:
        annotate("warning", "no base commit given, so new crates were not listed.")
        return 0
    base = sys.argv[1]
    lock = Path("Cargo.lock")
    if not lock.is_file():
        print("No Cargo.lock in the working tree; nothing to compare.")
        return 0
    try:
        rows = compare(base_lock(base), lock.read_text(encoding="utf-8"))
    except (LookupError, OSError, tomllib.TOMLDecodeError, KeyError) as error:
        annotate("warning", f"could not compare Cargo.lock with {base}: {error}")
        return 0

    for level, name, version, source in rows:
        what = "new crate" if level == "warning" else "new version"
        annotate(level, f"{what}: {name} {version} from {short_source(source)}")
    if not rows:
        print("Cargo.lock adds no crates.")

    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as out:
            out.write(summary(rows, base))
    return 0


if __name__ == "__main__":
    sys.exit(main())
