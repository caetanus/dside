#!/bin/sh
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# A D BINDING ARCHIVE MUST NOT DEFINE A C++ SYMBOL.
#
# A member with a D body inside an `extern(C++)` struct/class gets the C++ mangling of the Qt
# member it stands for. QTextTableCellFormat::setPadding(double) was such a body: a D forwarder to
# the shim `qtd_m_QTextTableCellFormat_8`, whose own C++ call to setPadding then resolved to that
# STRONG D definition — infinite recursion, a SIGSEGV 100k frames deep. And the executable exported
# the symbol, so the dynamic linker handed it to every shared library calling the same Qt inline:
# libsolidqml's ODF table import crashed on it. 2958 such definitions in the quick binding, any of
# them able to replace a Qt inline in a library the app loads.
#
# Every D body now carries D linkage. This reads the archive: any defined `_Z…` function fails it.
#   usage: no-cxx-defs.sh <libbinding_*.a>...
st=0
for a in "$@"; do
    n=$(nm --defined-only "$a" 2>/dev/null | awk 'NF==3 && $3 ~ /^_Z/ && $2 ~ /[TtWwVv]/' | wc -l)
    if [ "$n" -ne 0 ]; then
        echo "no-cxx-defs: FAIL $a defines $n C++-mangled symbol(s) — they can replace Qt's own:"
        nm --defined-only "$a" 2>/dev/null | awk 'NF==3 && $3 ~ /^_Z/ && $2 ~ /[TtWwVv]/ {print $3}' \
            | c++filt | sort -u | head -20 | sed 's/^/    /'
        st=1
    else
        echo "no-cxx-defs OK: $a defines no C++ symbol"
    fi
done
exit $st
