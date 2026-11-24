"""Builds dist/QueensDomain-Win64-Shipping.zip, the UEVR profile import for a release.

- Copies the mod scripts and data from the repo (skips *.pre-* backups, *.works, user_configuration.json).
- Strips the developer bridge (the qd_exec handler) from the release copy only; the repo keeps it for tests.
- Syntax-checks the stripped main script with Lua 5.4 (needs lupa in tools/pydeps).
- Writes the zip with forward slashes, so every unzip tool reads it.
Run from the repo root: python tools/build_release.py
"""
import os
import re
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(HERE, "pydeps"))
from lupa.lua54 import LuaRuntime  # noqa: E402

OUT = os.path.join(ROOT, "dist", "QueensDomain-Win64-Shipping.zip")
SCRIPTS = os.path.join(ROOT, "QueensDomain-Win64-Shipping", "scripts")
DATA = os.path.join(ROOT, "QueensDomain-Win64-Shipping", "data")
MAIN = os.path.join(SCRIPTS, "queens_domain_vr.lua")

# The developer bridge: registers the qd_exec handler that runs any Lua string sent to the game.
BRIDGE = re.compile(
    r'pcall\(function\(\)\r?\n\tuevr\.sdk\.callbacks\.on_lua_event\(function\(name, data\)\r?\n'
    r'.*?\[EXEC\] bridge ready"\)\r?\nend\)\r?\n',
    re.DOTALL,
)
EXCLUDE_DATA = {"user_configuration.json"}
TOP_FILES = [os.path.join(ROOT, "README.md"), os.path.join(ROOT, "ATTRIBUTIONS.md"), os.path.join(ROOT, "LICENSE"),
             os.path.join(ROOT, "licenses", "uevrlib-MIT.txt")]


def keep(name):
    return ".pre-" not in name and not name.endswith(".works")


def collect():
    """Yields (archive_path, source_path_or_bytes) for every release file."""
    for path in TOP_FILES:
        yield os.path.relpath(path, ROOT).replace(os.sep, "/"), path
    for base, arc in ((SCRIPTS, "scripts"), (DATA, "data")):
        for dirpath, _, files in os.walk(base):
            for f in files:
                if not keep(f) or (arc == "data" and f in EXCLUDE_DATA):
                    continue
                full = os.path.join(dirpath, f)
                rel = os.path.relpath(full, base).replace(os.sep, "/")
                yield f"{arc}/{rel}", full


def strip_bridge(src):
    stripped, n = BRIDGE.subn("", src)
    if n != 1:
        sys.exit(f"bridge block matched {n} times; expected 1. Update BRIDGE in build_release.py.")
    if 'name ~= "qd_exec"' in stripped or "on_lua_event(function(name, data)" in stripped:
        sys.exit("bridge handler still present after stripping.")
    return stripped


def syntax_check(src):
    lua = LuaRuntime(unpack_returned_tuples=True)
    result = lua.eval("load")(src, "queens_domain_vr")
    chunk, err = result if isinstance(result, tuple) else (result, None)
    if chunk is None:
        sys.exit(f"syntax error in stripped main script: {err}")


def main():
    files = list(collect())
    with open(MAIN, encoding="utf-8", newline="") as fh:
        main_src = fh.read()
    stripped = strip_bridge(main_src)
    syntax_check(stripped)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    if os.path.exists(OUT):
        os.remove(OUT)
    count = 0
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
        for arc, src in files:
            if arc == "scripts/queens_domain_vr.lua":
                z.writestr(arc, stripped.encode("utf-8"))
            else:
                z.write(src, arc)
            count += 1
    with zipfile.ZipFile(OUT) as z:
        names = z.namelist()
        for n in names:
            if n.endswith(".dll") or ".pre-" in n or "user_configuration" in n or "\\" in n:
                sys.exit(f"unexpected entry: {n}")
        if b'name ~= "qd_exec"' in z.read("scripts/queens_domain_vr.lua"):
            sys.exit("bridge still in the zip")
    print(f"wrote {os.path.relpath(OUT, ROOT)}: {count} entries, bridge stripped, main script compiles")


if __name__ == "__main__":
    main()
