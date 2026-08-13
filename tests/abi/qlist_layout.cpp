// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// ABI LAYOUT PROBE (critics r4 #9 — the oldest finding still untouched until 2026-08-12).
//
// The container bridge does not call Qt to read a QList: the generated D struct reads the FIELDS at
// offsets the generator hard-codes, because that is what makes a container crossing free instead of
// a copy. Those offsets got into the source the way the comment admits — "Verified empirically
// (offset=24 for QVector<double>)". An empirical offset is a correct offset until the day it is not,
// and on that day the failure is a wrong pointer, not a build error.
//
// This probe asserts the SAME layout the generator emits, against the Qt headers actually
// installed, and reads it two ways: through our offsets and through Qt's own API. When they stop
// agreeing it fails HERE, with the numbers, instead of somewhere downstream with a bad pointer —
// which is also what round 7 #7 asked for ("falha de private API diagnosticável como
// compatibilidade, não como um ./build vermelho indistinto").
//
// It is deliberately NOT a header-only static_assert: sizeof alone would pass a QList whose fields
// were reordered. The run-time half compares the values.

#include <QtCore/QList>
#include <QtCore/QString>
#include <QtCore/QVector>
#include <cstdio>
#include <cstddef>

static int failures = 0;

static void check(bool ok, const char* what, long long got, long long want)
{
    if (ok) return;
    std::fprintf(stderr, "abi-layout FAIL: %s — got %lld, Qt says %lld\n", what, got, want);
    ++failures;
}

#if QT_VERSION >= QT_VERSION_CHECK(6, 0, 0)
// Qt6 QList<T> == QVector<T> == QArrayDataPointer<T> { void* d; T* ptr; qsizetype size }.
// generator-d/emit_cxx.d emits exactly this shape for every element type it bridges.
template <typename T>
struct Adp { void* d; T* ptr; qsizetype size; };

template <typename T>
static void probeQt6(const char* name, const QList<T>& v)
{
    static_assert(sizeof(QList<T>) == sizeof(Adp<T>),
                  "Qt6 QList<T> is no longer {void* d; T* ptr; qsizetype size}");
    const Adp<T>* a = reinterpret_cast<const Adp<T>*>(&v);
    const bool sizeOk = a->size == v.size();
    const bool ptrOk  = (const void*) a->ptr == (const void*) v.constData();
    check(sizeOk, name, (long long) a->size, (long long) v.size());
    check(ptrOk, name, (long long) (quintptr) a->ptr, (long long) (quintptr) v.constData());
    // ...and the elements really are reachable through the field, not merely equal by address.
    // Only once the two above hold: a probe that dereferences a pointer it has just proved wrong
    // would report the layout change as a SEGFAULT, which is the diagnostic this exists to replace.
    if (!sizeOk || !ptrOk) return;
    for (qsizetype i = 0; i < v.size(); ++i)
        check(a->ptr[i] == v.at(i), name, (long long) i, (long long) i);
}
#else
// Qt5 QList<T> = { QListData::Data* d }; Data: ref@0, alloc@4, begin@8, end@12, void* array[]@16.
// Qt5 QVector<T> = { QArrayData* d }; QArrayData: ref@0, size@4, alloc@8, qptrdiff offset@16,
// data CONTIGUOUS at (char*)d + offset.
static void probeQt5List(const QList<int>& v)
{
    static_assert(sizeof(QList<int>) == sizeof(void*), "Qt5 QList<T> is no longer a single pointer");
    const char* d = *reinterpret_cast<const char* const*>(&v);
    const int begin = *reinterpret_cast<const int*>(d + 8);
    const int end   = *reinterpret_cast<const int*>(d + 12);
    check(end - begin == v.size(), "qt5 QList size (end-begin)", end - begin, v.size());
    if (end - begin != v.size()) return;   // see the Qt6 note: never deref a disproved layout
    void* const* arr = reinterpret_cast<void* const*>(d + 16);
    for (int i = 0; i < v.size(); ++i)   // <= sizeof(void*) and primitive: stored INLINE in the slot
        check(*reinterpret_cast<const int*>(&arr[begin + i]) == v.at(i),
              "qt5 QList element", i, i);
}

static void probeQt5Vector(const QVector<double>& v)
{
    static_assert(sizeof(QVector<double>) == sizeof(void*),
                  "Qt5 QVector<T> is no longer a single pointer");
    const char* d = *reinterpret_cast<const char* const*>(&v);
    const int size = *reinterpret_cast<const int*>(d + 4);
    const qptrdiff off = *reinterpret_cast<const qptrdiff*>(d + 16);
    check(size == v.size(), "qt5 QVector size@4", size, v.size());
    check((const void*) (d + off) == (const void*) v.constData(),
          "qt5 QVector data at d+offset@16", (long long) off, (long long) 0);
}
#endif

int main()
{
#if QT_VERSION >= QT_VERSION_CHECK(6, 0, 0)
    QList<int> ints;      ints << 3 << 1 << 4 << 1 << 5;
    QList<double> reals;  reals << 2.5 << -0.5;
    QList<QString> strs;  strs << QStringLiteral("alpha") << QStringLiteral("beta");
    probeQt6("qt6 QList<int>", ints);
    probeQt6("qt6 QList<double>", reals);
    probeQt6("qt6 QList<QString>", strs);
    // QVector/QStack/QQueue are QList in Qt6, and the generator relies on that to reuse one module.
    static_assert(sizeof(QVector<int>) == sizeof(QList<int>), "Qt6 QVector diverged from QList");
    if (!failures)
        std::printf("abi-layout OK (Qt6): QList<T> is {void* d; T* ptr; qsizetype size} — ptr and "
                    "size read through the generator's offsets equal Qt's own, for int, double and "
                    "QString; QVector is QList\n");
#else
    QList<int> ints;         ints << 3 << 1 << 4;
    QVector<double> reals;   reals << 2.5 << -0.5;
    probeQt5List(ints);
    probeQt5Vector(reals);
    if (!failures)
        std::printf("abi-layout OK (Qt5): QList begin@8/end@12/array@16 and QVector size@4/"
                    "offset@16 read through the generator's offsets equal Qt's own\n");
#endif
    return failures ? 1 : 0;
}
