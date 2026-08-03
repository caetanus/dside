#!/usr/bin/env python3
"""Bucket the VALUE differential (`--dumpall` vs the oracle) by what each difference MEANS.

The comparison script only counts differing lines, and a count cannot tell a wrong value from a
path the engine cannot reach. Both were reported as one number, and the biggest single bucket in
this corpus turned out to be neither side being wrong: Qt's `QQuickTransition` declares
`Q_CLASSINFO("DeferredPropertyNames", "animations")`, so the engine does not create a transition's
animations until the transition RUNS. At rest it has none, we have ours, and the diff blamed the
compiler for 155 paths that are simply not comparable yet.

The oracle already says so, in its own output: a path it cannot walk is printed as `<path>.<missing>`.
That marker is the whole rule here — every key of ours under such a path is UNMEASURABLE, not wrong.

Buckets:
  value-diff    both sides have the path, the values differ           -> a real defect
  only-ours     we have a path the engine has and did not print       -> a real defect
  unmeasurable  ours sits under a path the oracle marked <missing>    -> not comparable at rest
  only-engine   the engine has a path we never emit                   -> a real gap

Usage:  qmltc-value-census.py <dir with *.dall.s and *.qall.s> [--by-file]
"""
import sys, os, glob, collections


def read(path):
    m = {}
    for line in open(path):
        k, _, v = line.rstrip("\n").partition("\t")
        m[k] = v
    return m


def census(dall, qall):
    ours, eng = read(dall), read(qall)
    # The prefixes the oracle could not walk. `<path>.<missing>` means the walk stopped there, so
    # nothing under `<path>.` exists on the engine side to compare against.
    unreachable = [k[: -len(".<missing>")] + "." for k in eng if k.endswith(".<missing>")]
    out = collections.Counter()
    for k, v in ours.items():
        if k in eng:
            if eng[k] != v:
                out["value-diff"] += 1
        elif any(k.startswith(p) for p in unreachable):
            out["unmeasurable"] += 1
        else:
            out["only-ours"] += 1
    for k in eng:
        if k.endswith(".<missing>"):
            continue
        if k not in ours:
            out["only-engine"] += 1
    return out


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    d = sys.argv[1]
    by_file = "--by-file" in sys.argv
    total = collections.Counter()
    identical = docs = 0
    rows = []
    for dall in sorted(glob.glob(os.path.join(d, "*.dall.s"))):
        qall = dall[: -len(".dall.s")] + ".qall.s"
        if not os.path.exists(qall) or os.path.getsize(qall) == 0:
            continue
        docs += 1
        c = census(dall, qall)
        total.update(c)
        # "identical" means no REAL difference: an unmeasurable path is not one.
        if not (c["value-diff"] or c["only-ours"] or c["only-engine"]):
            identical += 1
        elif by_file:
            rows.append((os.path.basename(dall)[: -len(".dall.s")], c))
    print("documents\t%d" % docs)
    print("identical\t%d" % identical)
    for k in ("value-diff", "only-ours", "only-engine", "unmeasurable"):
        print("%s\t%d" % (k, total[k]))
    for name, c in sorted(rows, key=lambda r: -(r[1]["value-diff"] + r[1]["only-ours"] + r[1]["only-engine"])):
        print("  %-28s %s" % (name, dict(c)))


main()
