#!/bin/sh
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
# EVERY wrapper ctor that allocates must free on failure.
#
# Between `__cpp_new` and `_register()` nothing owns the block: the wrapper is not in the identity
# map and no finalizer knows the pointer, so a C++ constructor that throws — which the Lippincott
# layer turns into a QtCppException — leaked it. The emitter now puts `scope(failure) __cpp_delete`
# on the line after the allocation, and this checks that it is still there in every generated
# binding rather than trusting the emitter to stay correct.
#
# It is a STRUCTURAL gate, and that is a real limitation: it proves the guard is emitted, not that
# it fires. Proving that needs a bound class whose constructor throws, and no such fixture exists
# yet (Qt's own constructors do not throw) — inventoried as `ctor-throw-leaks-cpp-new`.
#
#   ctorguard.sh <generated dir>...
set -u
bad=0; n=0
for d in "$@"; do
  [ -d "$d" ] || continue
  for f in $(find "$d" -name '*.d' -path '*/qt/*'); do
    # every `auto __r = __cpp_new(` must be followed immediately by the guard
    miss=$(awk '/auto __r = __cpp_new\(/ { want=NR+1 }
                want && NR==want && $0 !~ /scope\(failure\) __cpp_delete\(__r\)/ { print FILENAME":"NR }
                { }' "$f")
    tot=$(grep -c 'auto __r = __cpp_new(' "$f" 2>/dev/null); tot=${tot:-0}
    n=$((n + tot))
    if [ -n "$miss" ]; then bad=$((bad + 1)); echo "$miss" | head -3; fi
  done
done
if [ "$n" -eq 0 ]; then echo "ctorguard: no generated wrapper ctors found — nothing was checked" >&2; exit 1; fi
[ "$bad" -eq 0 ] || { echo "ctorguard: $bad file(s) allocate without a scope(failure) guard" >&2; exit 1; }
echo "ctorguard OK: $n allocating wrapper ctor(s), every one frees the block on failure"
