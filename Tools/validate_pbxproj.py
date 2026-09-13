#!/usr/bin/env python3
"""Validate an Xcode project file without Xcode.

Parses project.pbxproj as an OpenStep plist and checks the things that make Xcode
refuse to open a project: malformed syntax, a missing rootObject, dangling object
references, and targets that don't point at real build phases or configurations.

Run:  python3 Tools/validate_pbxproj.py TalkForMac.xcodeproj/project.pbxproj
"""
import re
import sys


class ParseError(Exception):
    pass


def parse(text):
    """Minimal OpenStep plist parser: dicts, arrays, quoted and bare strings."""
    i = 0
    n = len(text)

    def skip():
        nonlocal i
        while i < n:
            if text[i] in " \t\r\n":
                i += 1
            elif text.startswith("//", i):
                while i < n and text[i] != "\n":
                    i += 1
            elif text.startswith("/*", i):
                end = text.find("*/", i)
                if end < 0:
                    raise ParseError("unterminated comment")
                i = end + 2
            else:
                return

    def value():
        nonlocal i
        skip()
        if i >= n:
            raise ParseError("unexpected end of file")
        char = text[i]
        if char == "{":
            i += 1
            result = {}
            while True:
                skip()
                if i < n and text[i] == "}":
                    i += 1
                    return result
                key = value()
                skip()
                if i >= n or text[i] != "=":
                    raise ParseError(f"expected '=' after key {key!r} at offset {i}")
                i += 1
                result[key] = value()
                skip()
                if i < n and text[i] == ";":
                    i += 1
                elif i < n and text[i] == "}":
                    continue
                else:
                    raise ParseError(f"expected ';' after value for {key!r} at offset {i}")
        if char == "(":
            i += 1
            result = []
            while True:
                skip()
                if i < n and text[i] == ")":
                    i += 1
                    return result
                result.append(value())
                skip()
                if i < n and text[i] == ",":
                    i += 1
                elif i < n and text[i] == ")":
                    continue
                else:
                    raise ParseError(f"expected ',' in array at offset {i}")
        if char == '"':
            i += 1
            out = []
            while i < n:
                if text[i] == "\\":
                    out.append(text[i + 1])
                    i += 2
                elif text[i] == '"':
                    i += 1
                    return "".join(out)
                else:
                    out.append(text[i])
                    i += 1
            raise ParseError("unterminated string")
        match = re.match(r"[A-Za-z0-9_./$:@~+\-*]+", text[i:])
        if not match:
            raise ParseError(f"unexpected character {text[i]!r} at offset {i}")
        i += match.end()
        return match.group(0)

    root = value()
    skip()
    if i != n:
        raise ParseError(f"trailing content at offset {i}")
    return root


def validate(path):
    text = open(path, encoding="utf-8").read()
    if not text.startswith("// !$*UTF8*$!"):
        return [f"{path}: missing the UTF-8 marker Xcode writes as the first line"]

    try:
        root = parse(text)
    except ParseError as error:
        return [f"{path}: {error}"]

    problems = []
    objects = root.get("objects")
    if not isinstance(objects, dict):
        return [f"{path}: no objects dictionary"]

    root_id = root.get("rootObject")
    if root_id not in objects:
        problems.append(f"rootObject {root_id} is not in objects")

    # Every 24-hex-ish identifier mentioned anywhere must exist.
    identifier = re.compile(r"^[A-F0-9]{24}$")

    def walk(node, where):
        if isinstance(node, dict):
            for key, item in node.items():
                walk(item, f"{where}.{key}")
        elif isinstance(node, list):
            for index, item in enumerate(node):
                walk(item, f"{where}[{index}]")
        elif isinstance(node, str) and identifier.match(node) and node not in objects:
            problems.append(f"dangling reference {node} at {where}")

    for key, obj in objects.items():
        walk(obj, key)
        if not isinstance(obj, dict) or "isa" not in obj:
            problems.append(f"object {key} has no isa")

    project = objects.get(root_id, {})
    targets = project.get("targets", [])
    if not targets:
        problems.append("the project has no targets")

    for target_id in targets:
        target = objects.get(target_id, {})
        name = target.get("name", target_id)
        for required in ("buildConfigurationList", "buildPhases", "productReference", "productType"):
            if required not in target:
                problems.append(f"target {name} is missing {required}")
        for phase in target.get("buildPhases", []):
            isa = objects.get(phase, {}).get("isa", "?")
            if not isa.startswith("PBX"):
                problems.append(f"target {name} references a non-phase {phase}")
        configurations = objects.get(target.get("buildConfigurationList", ""), {})
        names = [objects.get(c, {}).get("name") for c in configurations.get("buildConfigurations", [])]
        if sorted(filter(None, names)) != ["Debug", "Release"]:
            problems.append(f"target {name} has configurations {names}, expected Debug and Release")

    synchronized = [key for key, obj in objects.items()
                    if obj.get("isa") == "PBXFileSystemSynchronizedRootGroup"]
    if synchronized:
        version = int(root.get("objectVersion", "0"))
        if version < 70:
            problems.append(f"synchronized folder groups need objectVersion >= 70, found {version}")

    if not problems:
        target_names = [objects[t].get("name") for t in targets]
        print(f"{path}: OK — {len(objects)} objects, targets: {', '.join(target_names)}")
        for key in synchronized:
            print(f"  synchronized folder: {objects[key].get('path')}")
    return problems


if __name__ == "__main__":
    paths = sys.argv[1:] or ["TalkForMac.xcodeproj/project.pbxproj"]
    failures = []
    for path in paths:
        failures += validate(path)
    for failure in failures:
        print("  problem:", failure)
    sys.exit(1 if failures else 0)
