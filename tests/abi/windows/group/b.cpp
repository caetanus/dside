// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
extern "C" int a_helper();
extern "C" int b_fn() { return a_helper() * 2; }
