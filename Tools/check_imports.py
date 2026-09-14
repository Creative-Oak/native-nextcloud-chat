#!/usr/bin/env python3
"""Check that every Swift file imports the frameworks it uses.

A missing `import AppKit` in a SwiftUI file is invisible on Linux and an instant error on
a Mac, so this runs where there is no Xcode to tell us. It is a heuristic — it looks for
framework-specific symbols — but the symbols it looks for are unambiguous.

Run:  python3 Tools/check_imports.py
"""
import glob
import re
import sys

APP_RULES = {
    "AppKit": re.compile(r"\bNS[A-Z]\w+"),
    "Combine": re.compile(r"\.onReceive\("),
    "UserNotifications": re.compile(r"\bUN[A-Z]\w+"),
    "LinkPresentation": re.compile(r"\bLP[A-Z]\w+"),
    "SwiftData": re.compile(r"\b(ModelContainer|ModelContext|FetchDescriptor|PersistentModel|ModelConfiguration)\b"),
    "SwiftUI": re.compile(r"\b(View|Color|Text|VStack|HStack|Binding|Environment)\b"),
}

# Frameworks the core may only use behind a `canImport` guard, since it also builds on Linux.
CORE_RULES = {
    "Security": re.compile(r"\bSecItem\w*|kSec\w+"),
    "SwiftData": re.compile(r"\b(ModelContainer|FetchDescriptor|PersistentModel|ModelActor)\b"),
    "Network": re.compile(r"\bNWPathMonitor\b"),
    "CryptoKit": re.compile(r"\bSHA256\b"),
    "os": re.compile(r"\bOSLogType\b"),
}

FORBIDDEN_IN_CORE = re.compile(r"^\s*import\s+(SwiftUI|AppKit|UIKit)\s*$", re.M)


def strip_comments(source):
    source = re.sub(r"/\*.*?\*/", "", source, flags=re.S)
    return re.sub(r"//[^\n]*", "", source)


def check():
    problems = []

    for path in sorted(glob.glob("Kvidr/**/*.swift", recursive=True)):
        source = open(path, encoding="utf-8").read()
        body = strip_comments(source)
        header = source[:600]
        for framework, pattern in APP_RULES.items():
            if framework == "SwiftUI":
                continue  # too broad to require; the others are the useful signal
            if pattern.search(body) and f"import {framework}" not in header:
                sample = sorted(set(pattern.findall(body)))[:4]
                problems.append(f"{path}: uses {framework} ({', '.join(map(str, sample))}) without importing it")

    for path in sorted(glob.glob("Sources/TalkCore/**/*.swift", recursive=True)):
        source = open(path, encoding="utf-8").read()
        body = strip_comments(source)
        if FORBIDDEN_IN_CORE.search(body):
            problems.append(f"{path}: the core must not import a UI framework — it has to keep building on Linux")
        for framework, pattern in CORE_RULES.items():
            if pattern.search(body) and f"import {framework}" not in source:
                problems.append(f"{path}: uses {framework} without importing it")
            if pattern.search(body) and f"canImport({framework})" not in source and framework != "os":
                problems.append(f"{path}: uses {framework} without a canImport guard")

    return problems


if __name__ == "__main__":
    found = check()
    for problem in found:
        print("  problem:", problem)
    if not found:
        app = len(glob.glob("Kvidr/**/*.swift", recursive=True))
        core = len(glob.glob("Sources/TalkCore/**/*.swift", recursive=True))
        print(f"imports OK — {app} app files, {core} core files")
    sys.exit(1 if found else 0)
