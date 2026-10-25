#!/usr/bin/env python3
"""Normalize SystemCapabilities in the generated .pbxproj to native PBX dicts.

Background: capabilities are declared in project.yml under
`targets.<name>.attributes.SystemCapabilities`, but XcodeGen <= 2.46.0
serializes nested target attributes through `ProjectAttribute(any:)`,
emitting a quoted Swift-dictionary string instead of a PBX dictionary:

    SystemCapabilities = "[\"com.apple.SignInWithApple\": [\"enabled\": 1]]";

Xcode ignores that shape, so the capabilities silently vanish on every
`xcodegen generate` (upstream: yonaskolb/XcodeGen#1637). This hook rewrites
the malformed line into the native form Xcode expects:

    SystemCapabilities = {
        com.apple.SignInWithApple = {
            enabled = 1;
        };
    };

Wired via `options.postGenCommand` in project.yml, so it runs on every
regeneration — local, CI, and Xcode Cloud.

Retirement: if a future XcodeGen emits the native dict, this script prints
a notice (case 2 below) instead of rewriting. Delete this file and the
postGenCommand line when that happens.
"""

import re
import sys
from pathlib import Path

PBXPROJ = (
    Path.cwd() / "Shunik.xcodeproj" / "project.pbxproj"
)

# Quoted Swift-literal form emitted by the buggy generator, e.g.
#   SystemCapabilities = "[\"com.apple.A\": [\"enabled\": 1], ...]";
MALFORMED_RE = re.compile(
    r'^(?P<indent>[ \t]*)SystemCapabilities = "(?P<body>(?:[^"\\]|\\.)*)";$',
    re.MULTILINE,
)

# One capability entry inside the Swift literal:
#   \"com.apple.SignInWithApple\": [\"enabled\": 1]
ENTRY_RE = re.compile(r'\\"com\.apple\.(?P<cap>[^"\\]+)\\": \[\\"enabled\\": (?P<val>\d+)\]')

# Native form emitted by a fixed generator:
#   SystemCapabilities = {
NATIVE_RE = re.compile(r"^[ \t]*SystemCapabilities = \{$", re.MULTILINE)


def emit_native(indent: str, caps: list[tuple[str, int]]) -> str:
    lines = [f"{indent}SystemCapabilities = {{"]
    for name, val in sorted(caps):
        lines.append(f"{indent}\tcom.apple.{name} = {{")
        lines.append(f"{indent}\t\tenabled = {val};")
        lines.append(f"{indent}\t}};")
    lines.append(f"{indent}}};")
    return "\n".join(lines)


def main() -> int:
    if not PBXPROJ.is_file():
        print(f"error: {PBXPROJ} not found", file=sys.stderr)
        return 1
    text = PBXPROJ.read_text()

    matches = list(MALFORMED_RE.finditer(text))
    if matches:
        # One malformed line per target that declares SystemCapabilities
        # (app + each extension): normalize every one, walking in reverse
        # so earlier offsets stay valid.
        normalized: list[str] = []
        for m in reversed(matches):
            caps = [
                (e.group("cap"), int(e.group("val")))
                for e in ENTRY_RE.finditer(m.group("body"))
            ]
            if not caps:
                print(
                    "error: malformed SystemCapabilities line has unrecognized "
                    "content — inspect manually",
                    file=sys.stderr,
                )
                return 1
            text = (
                text[: m.start()]
                + emit_native(m.group("indent"), caps)
                + text[m.end() :]
            )
            normalized.append(
                ", ".join(f"com.apple.{c}" for c, _ in sorted(caps))
            )
        PBXPROJ.write_text(text)
        for names in reversed(normalized):
            print(f"normalized SystemCapabilities to native PBX dict ({names})")
        return 0

    if NATIVE_RE.search(text):
        print(
            "notice: XcodeGen now emits native SystemCapabilities — "
            "this hook can be retired (delete this script and the "
            "postGenCommand line in project.yml)",
            file=sys.stderr,
        )
        return 0

    print(
        "error: no SystemCapabilities found in either malformed or native "
        "form — project.yml attributes may have been removed while this "
        "hook is still wired",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
