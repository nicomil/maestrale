"""Summarize an fs_usage log into the folders CleanMyMac touched.

fs_usage pads its columns with spaces and paths may contain single spaces
("Application Support"), so a path is taken as everything between the syscall
column and the run of two or more spaces before the elapsed time.

Usage: python3 -I summarize_capture.py <fs_usage log> [depth]
Writes paths-<stamp>.txt (folders by frequency) and writes-<stamp>.txt (any
call that could change a file: unlink, rename, rmdir, truncate...).
"""

import collections
import os
import re
import sys

LINE = re.compile(
    r"^\S+\s+(?P<call>[A-Za-z_0-9]+(?:\[[^\]]*\])?)\s+.*?"
    r"(?P<path>/[^\s].*?)\s{2,}[0-9.]+(?:\s+W)?\s+(?P<proc>\S+)\s*$"
)
WRITE_CALLS = ("unlink", "rename", "rmdir", "truncate", "ftruncate", "removefile", "clonefile", "exchangedata")
NOISE = (
    "/dev/", "/System/Library/", "/usr/lib/", "/usr/share/", "/Library/Apple/",
    "/private/var/db/timezone", "/Applications/CleanMyMac_5.app", "/AppleInternal",
)


ROOTS = ("/Applications", "/Users", "/Library", "/private", "/Volumes", "/System", "/opt",
         "/usr", "/var", "/tmp", "/etc", "/cores", "/bin", "/sbin")


def fold(path: str, home: str, depth: int) -> str:
    path = re.sub(r"/{2,}", "/", path)
    # fs_usage cuts long paths from the left; those no longer start at a root.
    if not path.startswith(ROOTS):
        return "(tagliato da fs_usage)"
    if path.startswith(home + "/") or path == home:
        path = "~" + path[len(home):]
    parts = path.split("/")
    return "/".join(parts[: depth + 1]) if path.startswith("/") else "/".join(parts[:depth])


def main() -> None:
    log = sys.argv[1]
    depth = int(sys.argv[2]) if len(sys.argv) > 2 else 4
    home = os.path.expanduser("~")
    folders: collections.Counter[str] = collections.Counter()
    writes: list[str] = []

    with open(log, errors="replace") as handle:
        for line in handle:
            match = LINE.match(line)
            if not match:
                continue
            path, call = match["path"], match["call"]
            if path.startswith(NOISE):
                continue
            folders[fold(path, home, depth)] += 1
            if call.split("[")[0] in WRITE_CALLS:
                writes.append(f"{call}\t{match['proc']}\t{path}")

    stamp = os.path.basename(log).removeprefix("fs_usage-").removesuffix(".log")
    out_dir = os.path.dirname(log)
    paths_file = os.path.join(out_dir, f"paths-{stamp}.txt")
    writes_file = os.path.join(out_dir, f"writes-{stamp}.txt")
    with open(paths_file, "w") as out:
        for folder, count in folders.most_common():
            out.write(f"{count:9d}  {folder}\n")
    with open(writes_file, "w") as out:
        out.write("\n".join(writes) + ("\n" if writes else ""))
    print(f"Saved {paths_file} ({len(folders)} folders)")
    print(f"Saved {writes_file} ({len(writes)} write calls)")


if __name__ == "__main__":
    main()
