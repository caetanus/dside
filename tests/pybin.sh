# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# THE PYTHON THAT ACTUALLY RUNS — sourced, sets $PY.
#
# `python3` is the right name everywhere except Windows, where a CPython install ships only
# `python.exe` and the name `python3` is claimed by a Microsoft Store stub: it exists, it is on
# PATH, and running it prints
#
#     Python was not found; run without arguments to install from the Microsoft Store…
#
# and exits non-zero. A `command -v python3` therefore says yes and the gate dies anyway. So the
# test here is whether the interpreter RUNS, not whether the name resolves.
if python3 -c "" >/dev/null 2>&1; then
    PY=python3
elif python -c "" >/dev/null 2>&1; then
    PY=python
else
    echo "no working python3 or python on PATH" >&2
    exit 1
fi
