#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# WHAT Qt 6 RELEASES EXIST ON Qt'S OWN REPOSITORY — the watcher half of the release pipeline.
#
#   tools/ci/qt-latest.sh                     # every Qt 6 release, oldest first
#   tools/ci/qt-latest.sh --newest            # just the newest
#   tools/ci/qt-latest.sh --newer-than 6.11.1 # only what is newer than what we target
#
# This reads the same repository tools/linux/get-qt.sh installs from, the same way: a plain HTTP
# index. What it adds is DISCOVERY — get-qt.sh is told a version, this one asks which exist.
#
# WHY IT DOES NOT DECODE THE DIRECTORY NAME, which is the obvious implementation and is wrong. The
# index holds directories called `qt6_6111`, and reading that back as 6.11.1 needs a rule for where
# the minor ends and the patch begins. There is no such rule: `6.11.1` and `6.1.11` both encode to
# `6111`, and the ambiguity is not hypothetical — Qt 5.15 reached patch 17, so `51517` is a real
# shape and every split of it is a guess. A wrong guess does not fail here; it silently names a Qt
# that does not exist, and the first symptom is a 404 in a build an hour later.
#
# So a directory name is only a CANDIDATE, and the answer is read from the `<Version>` element in
# that directory's own Updates.xml, which Qt writes as `6.12.0-0-202609141059`.
set -euo pipefail

base=https://download.qt.io/online/qtsdkrepository/linux_x64/desktop
mode=all
floor=""
resolve=""

while [ $# -gt 0 ]; do
    case "$1" in
        --newest)     mode=newest; shift ;;
        --newer-than) mode=newer; floor=$2; shift 2 ;;
        --base)       base=$2; shift 2 ;;
        --resolve)    resolve=$2; shift 2 ;;   # internal: one candidate -> one version
        -h|--help)    sed -n '5,10p' "$0"; exit 0 ;;
        *) echo "qt-latest: unknown argument: $1" >&2; exit 2 ;;
    esac
done

command -v curl >/dev/null || { echo "qt-latest: curl is not on PATH" >&2; exit 1; }

# ---- resolving ONE candidate (the worker this re-invokes itself as) ---------------------------
#
# TWO LAYOUTS, because Qt has changed it: 6.8 and newer nest an extra level
# (`qt6_6120/qt6_6120/Updates.xml`), 6.7 and older are flat (`qt6_671/Updates.xml`). Measured, both
# answering 200 for their own era. Probed rather than chosen by version, because the version is
# exactly what is not known yet.
#
# A candidate answering neither prints nothing and exits 0: the index lists directories that are
# mid-publication and briefly incomplete, and a watcher that dies on one of those reports nothing
# on precisely the day a release lands. What keeps that silence from being blindness is the floor
# check further down — see there.
if [ -n "$resolve" ]; then
    xml=$(curl -fsS --max-time 60 "$base/$resolve/$resolve/Updates.xml" 2>/dev/null) ||
    xml=$(curl -fsS --max-time 60 "$base/$resolve/Updates.xml" 2>/dev/null) || exit 0
    # A HERESTRING, not a pipe, and `sed … q`, not `grep | head -1`. Both spellings of "stop at the
    # first match" make the WRITER take SIGPIPE when the reader quits early, and under
    # `pipefail`+`errexit` that ends the script at status 141 having printed nothing — with the
    # cause nowhere near the line that reads a version. Cost two runs here before it was believed.
    v=$(sed -n '/<Version>/{s|.*<Version>\([^<]*\)</Version>.*|\1|p;q;}' <<<"$xml")
    v=${v%%-*}                          # `-0-<timestamp>` is the packaging serial, not the version
    case "$v" in 6.*) printf '%s\n' "$v" ;; esac
    exit 0
fi

# ---- discovery --------------------------------------------------------------------------------
index=$(curl -fsS --max-time 60 "$base/") || {
    echo "qt-latest: cannot read the Qt repository index at $base/" >&2; exit 1
}
candidates=$(grep -oE 'qt6_[0-9]+' <<<"$index" | sort -u) || true
[ -n "$candidates" ] || { echo "qt-latest: the index listed no qt6_* directories" >&2; exit 1; }

# IN PARALLEL, because this is one request per release and there are forty of them: serially it ran
# for over a minute, which is the difference between a check that gets run and one that gets
# commented out. `-P 8` against a download mirror is polite and turns it into seconds.
versions=$(xargs -P 8 -I{} bash "$0" --base "$base" --resolve {} <<<"$candidates" | sort -uV) || true
[ -n "$versions" ] || { echo "qt-latest: no Qt 6 release answered with a version" >&2; exit 1; }

case "$mode" in
    all)    printf '%s\n' "$versions" ;;
    newest) printf '%s\n' "$versions" | tail -1 ;;
    newer)
        [ -n "$floor" ] || { echo "qt-latest: --newer-than needs a version" >&2; exit 2; }
        # THE FLOOR MUST BE VISIBLE, and this is the check the whole script is built around. Every
        # failure above is a silent skip, so a repository layout this no longer understands does not
        # produce an error — it produces a SHORTER LIST. A shorter list, asked "is anything newer?",
        # answers no. That is the same answer a quiet week gives, so a watcher gone blind and a
        # watcher with nothing to report become indistinguishable from the outside, forever.
        #
        # The version we already target is the one release we KNOW is there. If it is missing from
        # what was discovered, the view is broken, and the honest output is a failure, not silence.
        if ! grep -qxF "$floor" <<<"$versions"; then
            echo "qt-latest: the repository did not report $floor, the version we target." >&2
            echo "    This is NOT 'nothing new'. It means this script no longer understands the" >&2
            echo "    repository layout, and would answer 'nothing new' for every future release." >&2
            echo "    Discovered: $(tr '\n' ' ' <<<"$versions")" >&2
            exit 1
        fi
        # STRICTLY newer, decided by `sort -V` rather than a string compare: 6.9.3 is older than
        # 6.10.0 and every lexical comparison in the world says the opposite.
        while IFS= read -r v; do
            [ "$v" = "$floor" ] && continue
            [ "$(printf '%s\n%s\n' "$floor" "$v" | sort -V | tail -1)" = "$v" ] && printf '%s\n' "$v"
        done <<<"$versions"
        ;;
esac
