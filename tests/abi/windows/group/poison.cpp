// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// Nothing references this. Its body calls a symbol that exists NOWHERE, so if the
// linker pulls the member in anyway, the link fails and we learn that member
// selection is not happening.
extern "C" int never_defined_anywhere();
extern "C" int poison() { return never_defined_anywhere(); }
