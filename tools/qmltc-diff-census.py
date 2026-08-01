#!/usr/bin/env python3
"""Compare the compiled dump against the engine's, and SEPARATE the two kinds of difference.

A property that differs in VALUE is a defect. A path that exists on one side and not on the
other is a question about the harness or about Qt, and lumping them together is how a single
number stops meaning anything: this corpus went 96 -> 216 "divergences" in one commit, and the
delta was neither a regression nor noise — `transition.animations[N]` exists on the compiled
side while Qt's public list reports empty at construction. I called it oracle blindness, then
called that correction wrong, before reducing it to a minimal document. One counter that
distinguishes the cases would have answered it immediately.

Input: a directory holding <name>.dall.s (compiled) and <name>.qall.s (engine) pairs, as
produced by the corpus differential.
"""
import sys, os, glob, collections

def load(p):
    d = {}
    for line in open(p, errors="replace"):
        if "\t" in line:
            k, v = line.rstrip("\n").split("\t", 1)
            d[k] = v
    return d

def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    verbose = "--list" in sys.argv
    files = ident = 0
    value_diff, only_ours, only_engine = [], [], []
    for f in sorted(glob.glob(os.path.join(root, "*.dall.s"))):
        q = f[:-7] + ".qall.s"
        n = os.path.basename(f)[:-7]
        if not os.path.exists(q) or os.path.getsize(q) == 0:
            continue
        a, b = load(f), load(q)
        files += 1
        d = 0
        for k in set(a) | set(b):
            if a.get(k) == b.get(k):
                continue
            d += 1
            if k not in b or b.get(k) == "<missing>":
                only_ours.append(f"{n}:{k}")
            elif k not in a:
                only_engine.append(f"{n}:{k}")
            else:
                value_diff.append((f"{n}:{k}", a[k], b[k]))
        ident += (d == 0)
    print(f"files\t{ident}/{files} identical")
    print(f"value-diff\t{len(value_diff)}\t<- defects: both sides have the property, values differ")
    print(f"only-ours\t{len(only_ours)}\t<- path absent in the ENGINE (harness or Qt question)")
    print(f"only-engine\t{len(only_engine)}\t<- path absent in OURS (usually a refused binding)")
    if verbose:
        for k, x, y in value_diff[:40]:
            print(f"  {k[:56]:58} ours={str(x)[:16]:18} engine={str(y)[:16]}")
        for k in only_ours[:10]:
            print(f"  only-ours  {k[:70]}")

if __name__ == "__main__":
    main()
