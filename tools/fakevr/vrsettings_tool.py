"""Surgical editor for SteamVR's steamvr.vrsettings (used by fakevr.ps1).

Only the two keys steamvr.forcedDriver / steamvr.activateMultipleDrivers are
touched; every other byte of the file is preserved. The result is re-parsed and
compared with the intended dict before it is written (atomic replace).

usage: python -I vrsettings_tool.py status|on|off <steamvr.vrsettings> <state.json>
"""
import json
import os
import sys

KEYS = {"forcedDriver": "qdfake", "activateMultipleDrivers": True}


def scan_members(text, start, end):
    """Members of the JSON object whose braces are text[start] .. text[end-1].
    Returns [(key, member_start, value_start, value_end)] for depth-1 members."""
    out, i, depth = [], start + 1, 0
    key = kpos = None
    while i < end - 1:
        ch = text[i]
        if ch == '"':
            j = i + 1
            while text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            if depth == 0 and key is None:
                key, kpos = json.loads(text[i:j + 1]), i
                i = j + 1
                while text[i] in " \t\r\n":
                    i += 1
                assert text[i] == ":", "expected ':'"
                i += 1
                while text[i] in " \t\r\n":
                    i += 1
                vstart = i
                continue
            i = j + 1
            continue
        if ch in "{[":
            depth += 1
        elif ch in "}]":
            depth -= 1
        elif ch == "," and depth == 0 and key is not None:
            out.append((key, kpos, vstart, rstrip_pos(text, vstart, i)))
            key = None
        i += 1
    if key is not None:
        out.append((key, kpos, vstart, rstrip_pos(text, vstart, end - 1)))
    return out


def rstrip_pos(text, lo, hi):
    while hi > lo and text[hi - 1] in " \t\r\n":
        hi -= 1
    return hi


def object_span(text, value_start):
    assert text[value_start] == "{"
    depth, i = 0, value_start
    while True:
        ch = text[i]
        if ch == '"':
            i += 1
            while text[i] != '"':
                i += 2 if text[i] == "\\" else 1
        elif ch == "{" or ch == "[":
            depth += 1
        elif ch == "}" or ch == "]":
            depth -= 1
            if depth == 0:
                return value_start, i + 1
        i += 1


def lit(v):
    return json.dumps(v)


def edit(text, changes):
    """changes: {key: value or REMOVE} applied inside top-level "steamvr" object."""
    nl = "\r\n" if "\r\n" in text else "\n"
    top = text.index("{")
    _, top_end = object_span(text, top)
    members = {k: (ms, vs, ve) for k, ms, vs, ve in scan_members(text, top, top_end)}
    if "steamvr" not in members:
        if all(v is REMOVE for v in changes.values()):
            return text
        body = (",").join(f'{nl}      "{k}" : {lit(v)}' for k, v in changes.items() if v is not REMOVE)
        insert = f'{nl}   "steamvr" : {{{body}{nl}   }}' + ("," if members else "")
        return text[:top + 1] + insert + text[top + 1:]
    s_start, s_end = object_span(text, members["steamvr"][1])
    for key, val in changes.items():
        mem = {k: (ms, vs, ve) for k, ms, vs, ve in scan_members(text, s_start, s_end)}
        if key in mem:
            ms, vs, ve = mem[key]
            if val is REMOVE:
                order = sorted(mem.values())
                idx = order.index((ms, vs, ve))
                line_start = text.rfind("\n", 0, ms) + 1
                if idx + 1 < len(order):  # remove "key : value," plus its line
                    nxt = order[idx + 1][0]
                    cut_from, cut_to = line_start, text.rfind("\n", 0, nxt) + 1
                    if text[line_start:ms].strip():  # members share a line
                        cut_from, cut_to = ms, nxt
                elif idx > 0:  # last member: drop the preceding comma
                    prev_end = order[idx - 1][2]
                    cut_from, cut_to = prev_end, ve
                else:  # only member
                    cut_from, cut_to = s_start + 1, s_end - 1
                text = text[:cut_from] + text[cut_to:]
            else:
                text = text[:vs] + lit(val) + text[ve:]
        elif val is not REMOVE:
            order = sorted(mem.values())
            if order:
                first = order[0][0]
                line_start = text.rfind("\n", 0, first) + 1
                indent = text[line_start:first] if not text[line_start:first].strip() else "      "
                ins = f'"{key}" : {lit(val)},{nl}{indent}'
                text = text[:first] + ins + text[first:]
            else:
                text = text[:s_start + 1] + f'{nl}      "{key}" : {lit(val)}{nl}   ' + text[s_end - 1:]
        s_start, s_end = object_span(text, s_start)
    return text


class _Remove:
    def __repr__(self):
        return "REMOVE"


REMOVE = _Remove()


def apply(path, changes):
    with open(path, "rb") as f:
        raw = f.read()
    bom = raw.startswith(b"\xef\xbb\xbf")
    text = raw[3:].decode("utf-8") if bom else raw.decode("utf-8")
    before = json.loads(text)
    expected = json.loads(text)
    sv = expected.setdefault("steamvr", {})
    for k, v in changes.items():
        if v is REMOVE:
            sv.pop(k, None)
        else:
            sv[k] = v
    new = edit(text, changes)
    if json.loads(new) != expected:
        sys.exit("vrsettings_tool: edit verification failed, file NOT written")
    if new == text:
        print("steamvr.vrsettings unchanged")
        return before
    tmp = path + ".qdfake.tmp"
    with open(tmp, "wb") as f:
        f.write((b"\xef\xbb\xbf" if bom else b"") + new.encode("utf-8"))
    os.replace(tmp, path)
    print("steamvr.vrsettings updated:", {k: ("<removed>" if v is REMOVE else v) for k, v in changes.items()})
    return before


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in ("status", "on", "off"):
        sys.exit(__doc__)
    cmd, path, state_path = sys.argv[1:]
    with open(path, "rb") as f:
        cur = json.loads(f.read().decode("utf-8-sig")).get("steamvr", {})
    if cmd == "status":
        print(json.dumps({k: cur.get(k, "<unset>") for k in KEYS}))
        print("saved previous values:", open(state_path).read().strip() if os.path.exists(state_path) else "<none>")
        return
    if cmd == "on":
        if not os.path.exists(state_path):  # remember pre-fake values exactly once
            prev = {k: ({"present": True, "value": cur[k]} if k in cur else {"present": False}) for k in KEYS}
            if cur.get("forcedDriver") == "qdfake":  # unknown original; assume unset
                prev = {k: {"present": False} for k in KEYS}
            with open(state_path, "w") as f:
                json.dump(prev, f)
        apply(path, dict(KEYS))
        return
    # off
    if os.path.exists(state_path):
        prev = json.load(open(state_path))
        changes = {k: (prev[k]["value"] if prev.get(k, {}).get("present") else REMOVE) for k in KEYS}
    elif cur.get("forcedDriver") == "qdfake":
        print("warning: no saved state; removing both keys")
        changes = {k: REMOVE for k in KEYS}
    else:
        print("fake mode not active in settings; nothing to restore")
        return
    apply(path, changes)
    if os.path.exists(state_path):
        os.remove(state_path)


if __name__ == "__main__":
    main()
