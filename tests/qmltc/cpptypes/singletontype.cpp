// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
//
// WRITTEN HERE, against the upstream declaration — not copied.
//
// `singletontype.h` beside this file IS Qt's (Copyright (C) 2022 The Qt Company Ltd.,
// LicenseRef-Qt-Commercial OR GPL-3.0-only) and declares `SingletonType`. The link needs a
// definition for the constructor it declares, and until 2026-08-14 that definition sat here with no
// header of any kind. It was the last file in this repository whose terms were unestablished, and
// it is what kept `license-coverage.sh --publish` red.
//
// Round 17 #1 named the two honest ways out: establish the provenance against upstream, or write
// our own implementation. The qtdeclarative sources are not available here to hash against, so this
// is the second: the body below is written for this repository, and it is the only body the
// declaration admits — a constructor that forwards its parent to QObject. Declaring an API and
// calling into Qt is not copying; had this been taken from upstream it would keep upstream's terms,
// and the commit that introduced it would say so.

#include "singletontype.h"

SingletonType::SingletonType(QObject *parent) : QObject{ parent } { }
