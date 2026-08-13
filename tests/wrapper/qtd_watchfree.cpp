// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// WATCH ONE BLOCK. A freed C++ block is not observable from D, and the two cheaper substitutes are
// both false discriminators — this file exists because each was tried and passed against a
// deliberately broken binding:
//
//   the identity map        unregistering happens in the base finalizer whether or not anything
//                           was deleted, so an unregistered wrapper says nothing about the object;
//   a global free counter   a collection frees plenty of unrelated blocks, so "more frees than
//                           before" is true even when the one under test leaked.
//
// So: name the address, then ask whether THAT block was freed. The `delete` under test is in the
// binding's own shim, compiled into this binary, which is why interposing works here — it does not
// for deletes that happen inside Qt's already-linked libraries.
#include <cstddef>
#include <cstdlib>

static void* g_watch = nullptr;
static int   g_freed = 0;

extern "C" void qtd_watch(void* p) { g_watch = p; g_freed = 0; }
extern "C" int  qtd_watch_freed()  { return g_freed; }

void operator delete(void* p) noexcept              { if (p && p == g_watch) g_freed = 1; if (p) std::free(p); }
void operator delete(void* p, std::size_t) noexcept { if (p && p == g_watch) g_freed = 1; if (p) std::free(p); }
