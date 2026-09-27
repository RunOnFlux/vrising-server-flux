#!/usr/bin/env python3
"""Makes BepInEx.cfg hold the three settings a V Rising server under Wine needs.

    flux-bepinex-cfg.py <path to BepInEx.cfg>

  [Logging.Console] Enabled = false
      BepInEx does not start under Wine with its console on (the previous image's README).
  [IL2CPP] ScanMethodRefs = false
      the cross-reference scan walks the whole game assembly, and on the 8 GB plan it did not
      fit in memory next to the game.
  [IL2CPP] PreloadIL2CPPInteropAssemblies = false
      otherwise every generated assembly is loaded at once straight after generation, on top of
      the generator's memory: the moment an 8 GB server died.

The community BepInExPack_V_Rising ships a BepInEx.cfg with NEITHER [IL2CPP] key, and the file
uses CRLF line endings. Idempotent: a file that already says all three is written back unchanged.

WHY THIS LIVES IN THE IMAGE. The games hub used to do it with sed after installing the pack, and
the sed was wrong: inserting ScanMethodRefs kept the matched line's own CR and added another, so
the header became "[IL2CPP]\\r\\r", and the second insertion, which looked for "[IL2CPP]" with at
most one CR, never matched. PreloadIL2CPPInteropAssemblies was never written on any server. This
also repairs that doubled CR.
"""
import re
import sys

SECTION_KEYS = {
    "Logging.Console": {"Enabled": "false"},
    "IL2CPP": {"ScanMethodRefs": "false", "PreloadIL2CPPInteropAssemblies": "false"},
}


def fix(text):
    newline = "\r\n" if "\r\n" in text else "\n"
    # Split on the newline only, keeping any stray CR on the line so it can be seen and repaired.
    lines = text.split("\n")
    section = None
    seen = {s: set() for s in SECTION_KEYS}
    header_at = {}
    out = []
    for line in lines:
        bare = line.rstrip("\r")
        header = re.match(r"^\[([^\]]+)\]\s*$", bare)
        if header:
            section = header.group(1)
            # One CR at most, whatever an earlier tool left there.
            line = bare + ("\r" if newline == "\r\n" else "")
            if section in SECTION_KEYS and section not in header_at:
                header_at[section] = len(out)
            out.append(line)
            continue
        if section in SECTION_KEYS:
            setting = re.match(r"^\s*([A-Za-z0-9_.]+)\s*=", bare)
            if setting and setting.group(1) in SECTION_KEYS[section]:
                key = setting.group(1)
                seen[section].add(key)
                line = f"{key} = {SECTION_KEYS[section][key]}" + ("\r" if newline == "\r\n" else "")
        out.append(line)

    cr = "\r" if newline == "\r\n" else ""
    # Missing keys go right under their section header, in a stable order. A missing section is
    # appended whole.
    for section in sorted(SECTION_KEYS, key=lambda s: -header_at.get(s, -1)):
        missing = [k for k in SECTION_KEYS[section] if k not in seen[section]]
        if not missing:
            continue
        block = []
        for key in missing:
            block += [cr, f"{key} = {SECTION_KEYS[section][key]}{cr}"]
        if section in header_at:
            at = header_at[section] + 1
            out[at:at] = block
        else:
            out += [cr, f"[{section}]{cr}"] + block
    return "\n".join(out)


def main(path):
    with open(path, encoding="utf-8", newline="") as f:
        before = f.read()
    after = fix(before)
    if after != before:
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write(after)
        print("updated")
    else:
        print("unchanged")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        sys.exit(64)
    main(sys.argv[1])
