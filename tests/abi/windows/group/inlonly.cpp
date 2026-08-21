// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A member NOTHING references, whose out-of-line inline copy needs a symbol that is not
// linked. This is the webengine shape: the offending code lives in its OWN object file.
extern "C" int absent_symbol();
inline int unused_inline() { return absent_symbol(); }
extern "C" int force_emit() { return unused_inline(); }
