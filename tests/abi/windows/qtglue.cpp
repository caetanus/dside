// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
#include <QByteArray>
extern "C" void* mkba(const char* s) { return new QByteArray(s); }
