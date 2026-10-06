// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
#include "reclist.h"

static int g_live = 0;

RecItem::RecItem() : m_n(0) { ++g_live; }
RecItem::RecItem(const QString &name, int n) : m_name(name), m_n(n) { ++g_live; }
RecItem::RecItem(const RecItem &o) : m_name(o.m_name), m_n(o.m_n) { ++g_live; }
RecItem &RecItem::operator=(const RecItem &o) { m_name = o.m_name; m_n = o.m_n; return *this; }
RecItem::~RecItem() { --g_live; }
QString RecItem::name() const { return m_name; }
int RecItem::n() const { return m_n; }
int RecItem::live() { return g_live; }

RecHost::~RecHost() = default;

QList<RecItem> RecHost::make(int count) {
    QList<RecItem> r;
    for (int i = 0; i < count; ++i) r.append(RecItem(QString::fromUtf8("item%1").arg(i), i * 10));
    return r;
}
QVector<RecItem> RecHost::makeVec(int count) {
    QVector<RecItem> r;
    for (int i = 0; i < count; ++i) r.append(RecItem(QString::fromUtf8("v%1").arg(i), i));
    return r;
}
int RecHost::total(const QList<RecItem> &items) {
    int t = 0;
    for (const auto &it : items) t += it.n();
    return t;
}
QString RecHost::names(const QList<RecItem> &items) {
    QString s;
    for (const auto &it : items) { if (!s.isEmpty()) s += QLatin1Char(','); s += it.name(); }
    return s;
}
