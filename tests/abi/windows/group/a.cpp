// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
extern "C" int b_fn();
extern "C" int a_fn() { return b_fn() + 1; }
