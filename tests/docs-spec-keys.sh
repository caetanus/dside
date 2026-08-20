#!/bin/sh
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# THE SPEC REFERENCE IS COMPARED AGAINST THE GENERATOR, BOTH WAYS.
#
#   docs-spec-keys.sh
#
# The spec is xiboca's entire user interface, so its reference page is the one
# document a reader cannot work around by reading the source — which is exactly why
# it must not be allowed to drift. Two directions, both fatal:
#
#   * a key the generator READS and the page does not document: a reader cannot
#     discover it except by reading emit.d, which is the situation this page exists
#     to end;
#   * a key the page DOCUMENTS and the generator never reads: worse, because it
#     invites someone to write it in a spec and expect an effect. Measured on
#     2026-08-18, before this gate existed: the page listed `no_transfer` beside
#     `transfer_in`/`transfer_out` as though xiboca read it. It does not — the
#     ownership GATE does — so entries added there would have changed nothing and
#     the reader would have had no way to tell.
#
# Keys are read out of the source the same way the generator reads them, rather
# than from a hand-kept list: a list would be a third place to forget.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

python3 - "$ROOT" <<'PY'
import re, sys, pathlib, glob

root = pathlib.Path(sys.argv[1])
src = "".join(p.read_text() for p in sorted((root / "xiboca").glob("*.d")))

# The two shapes the generator uses to reach a spec key.
code = set(re.findall(r'"([a-z_]+)"\s+in\s+spec\.object', src)) \
     | set(re.findall(r'spec\["([a-z_]+)"\]', src))

page = root / "docs" / "manual" / "xiboca" / "spec.rst"
own  = root / "docs" / "manual" / "xiboca" / "ownership.rst"
if not page.exists():
    print("docs-spec-keys FAIL: %s is missing" % page, file=sys.stderr); sys.exit(1)

# ``literal`` is how the reference names a key; ownership.rst carries the four
# ownership keys, and spec.rst says so rather than repeating them.
documented = set()
for f in (page, own):
    documented |= set(re.findall(r'``([a-z_]+)``', f.read_text()))

undocumented = sorted(code - documented)
# Only keys that LOOK like spec keys can be phantoms: the pages legitimately mention
# runtime and file names in literals too, so the phantom check is limited to names
# the reference presents in its own tables.
tabled = set(re.findall(r'\*\s+-\s+``([a-z_]+)``', page.read_text())) \
       | set(re.findall(r'\*\s+-\s+``([a-z_]+)``', own.read_text()))
phantom = sorted(tabled - code - {"no_transfer"})   # no_transfer is the gate's, and says so

if undocumented:
    print("docs-spec-keys FAIL: the generator reads %d key(s) the reference does not document:"
          % len(undocumented), file=sys.stderr)
    for k in undocumented:
        print("    %s" % k, file=sys.stderr)
if phantom:
    print("docs-spec-keys FAIL: the reference documents %d key(s) nothing reads:"
          % len(phantom), file=sys.stderr)
    for k in phantom:
        print("    %s — a reader would write it into a spec and get no effect" % k,
              file=sys.stderr)
if undocumented or phantom:
    sys.exit(1)

print("docs-spec-keys OK: %d spec key(s), each read by the generator and documented "
      "in the reference, and no documented key the generator ignores" % len(code))
PY
