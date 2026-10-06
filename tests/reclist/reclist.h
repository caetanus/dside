// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A VALUE RECORD with a user-provided copy constructor and destructor and a QString inside — the
// shape of Qt's own d-pointer records (QDnsMailExchangeRecord & co.) — and a host that returns and
// takes QList/QVector of it. `live()` counts instances, so a test can see every copy and every
// destruction the binding performs: a byte copy where a real one was needed, or a leaked or doubly
// destroyed element, moves the count.
#pragma once
#include <QList>
#include <QVector>
#include <QString>

class RecItem {
public:
    RecItem();
    RecItem(const QString &name, int n);
    RecItem(const RecItem &o);
    RecItem &operator=(const RecItem &o);
    ~RecItem();
    QString name() const;
    int n() const;
    static int live();
private:
    QString m_name;
    int m_n;
};

// A POLYMORPHIC class, like QDnsLookup (a QObject): the binding emits it as a class, and the
// container paths are the class emitter's. A struct-shaped host would test a different emitter.
class RecHost {
public:
    virtual ~RecHost();
    static QList<RecItem> make(int count);          // a QList of records by value
    static QVector<RecItem> makeVec(int count);     // the QVector spelling (== QList on Qt6)
    static int total(const QList<RecItem> &items);  // ...and one taken by const&
    static QString names(const QList<RecItem> &items);
};
