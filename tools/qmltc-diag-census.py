#!/usr/bin/env python3
"""Classify qmltc-d's refusals into CATEGORIES, from .diag files.

CRITICS' thesis applied to the compiler's own output: a refusal is a STATE, not a line of
prose. Every count in the audit notes was produced by an ad-hoc version of this script; a
census that lives in the repo can be diffed, gated and trusted, and one that lives in a
scratchpad cannot.

Usage:  qmltc-diag-census.py <dir-with-*.diag> [--by-file]

The categories are the compiler's own wording, not an interpretation of it. Anything that
matches none of them is reported as `other` WITH its text, because a bucket nobody can read
is how a class stays opaque — that happened twice in this corpus and cost several rounds.
"""
import sys, re, os, glob, collections

CATS = [
    ("expression",        r"not yet supported: expression for"),
    ("declared-type",     r"not yet supported: declared type"),
    ("no-notify",         r"no known notify"),
    ("not-grouped",       r"is not a grouped property"),
    ("component",         r"takes a Component"),
    ("member-unhandled",  r"is not yet handled"),
    ("not-scalar",        r"is not a scalar"),
    ("unsupported-bind",  r"unsupported binding/type"),
    ("unbound-type",      r"not a bound (Qt )?type"),
    ("state-shape",       r"uses a shape not compiled"),
]

def classify(line):
    for name, rx in CATS:
        if re.search(rx, line):
            return name
    return "other"

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    by_file = "--by-file" in sys.argv
    root = args[0] if args else "."
    cats, per_file, others = collections.Counter(), collections.Counter(), collections.Counter()
    total = 0
    for path in sorted(glob.glob(os.path.join(root, "*.diag"))):
        for line in open(path, errors="replace"):
            if not line.strip():
                continue
            total += 1
            c = classify(line)
            cats[c] += 1
            per_file[os.path.basename(path)[:-5]] += 1
            if c == "other":
                m = re.search(r"\.qml: (.{0,70})", line)
                others[(m.group(1) if m else line.strip())[:70]] += 1
    print(f"total\t{total}")
    for c, n in cats.most_common():
        print(f"{c}\t{n}")
    if others:
        print("\n# `other` in full — an unreadable bucket is how a class stays opaque")
        for txt, n in others.most_common():
            print(f"  {n:4d}  {txt}")
    if by_file:
        print("\n# by file")
        for f, n in per_file.most_common():
            print(f"  {n:4d}  {f}")

if __name__ == "__main__":
    main()
