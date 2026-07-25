// qtd_convert.cpp — hand-written conversion helpers (written once per Qt type,
// reused by the generator for every instantiation). Proves the marshaling
// pattern for QString<->string and QList<T> as a D range.
#include <QByteArray>
#include <QDir>
#include <QHash>
#include <QList>
#include <QMetaType>
#include <QString>
#include <QUrl>
#include <QVariant>
#include <cstdlib>
#include <cstring>

typedef QHash<QString, QString> HSS;
typedef HSS::const_iterator HSSit;

// Returns an owned utf8 buffer of `b` (caller frees via qtd_free); *n = length.
static const char *own(const QByteArray &b, size_t *n) {
    *n = (size_t) b.size();
    char *out = (char *) malloc(*n ? *n : 1);
    memcpy(out, b.constData(), *n);
    return out;
}

extern "C" {

// --- QString <-> D string : transport is (utf8 ptr, len) -------------------
void *qtd_qstring_from_utf8(const char *p, size_t n) {
    return new QString(QString::fromUtf8(p, (int) n));   // no NUL-termination needed
}
const char *qtd_qstring_utf8(void *h, size_t *n) {
    return own(static_cast<QString *>(h)->toUtf8(), n);
}
void qtd_qstring_delete(void *h) { delete static_cast<QString *>(h); }
void qtd_free(void *p) { free(p); }

// --- QByteArray <-> D string (bytes) ---------------------------------------
void *qtd_qbytearray_from(const char *p, size_t n) { return new QByteArray(p, (int) n); }
const char *qtd_qbytearray_data(void *h, size_t *n) {
    return own(*static_cast<QByteArray *>(h), n);
}
void qtd_qbytearray_delete(void *h) { delete static_cast<QByteArray *>(h); }

// --- QUrl <-> D string : local-file-friendly (AssumeLocalFile) -------------
void *qtd_qurl_from(const char *p, size_t n) {
    return new QUrl(QUrl::fromUserInput(QString::fromUtf8(p, (int) n),
                                        QDir::currentPath(), QUrl::AssumeLocalFile));
}
const char *qtd_qurl_to(void *h, size_t *n) {
    return own(static_cast<QUrl *>(h)->toString().toUtf8(), n);
}
void qtd_qurl_delete(void *h) { delete static_cast<QUrl *>(h); }

// --- QVariant <-> D QtVariant (tagged) -------------------------------------
void *qtd_qvariant_new()                     { return new QVariant(); }
void *qtd_qvariant_from_long(long long v)    { return new QVariant(v); }
void *qtd_qvariant_from_double(double v)     { return new QVariant(v); }
void *qtd_qvariant_from_bool(int v)          { return new QVariant((bool) v); }
void *qtd_qvariant_from_string(const char *p, size_t n) {
    return new QVariant(QString::fromUtf8(p, (int) n));
}
void qtd_qvariant_delete(void *h) { delete static_cast<QVariant *>(h); }

// kind: 0=invalid 1=bool 2=integer 3=floating 4=string 5=other
int qtd_qvariant_kind(void *h) {
    QVariant *v = static_cast<QVariant *>(h);
    if (!v->isValid()) return 0;
    switch (v->userType()) {   // userType() works on both Qt5 and Qt6 (typeId() is Qt6-only)
        case QMetaType::Bool: return 1;
        case QMetaType::Int: case QMetaType::UInt:
        case QMetaType::LongLong: case QMetaType::ULongLong: return 2;
        case QMetaType::Double: case QMetaType::Float: return 3;
        case QMetaType::QString: return 4;
        default: return 5;
    }
}
long long qtd_qvariant_to_long(void *h)   { return static_cast<QVariant *>(h)->toLongLong(); }
double    qtd_qvariant_to_double(void *h) { return static_cast<QVariant *>(h)->toDouble(); }
int       qtd_qvariant_to_bool(void *h)   { return static_cast<QVariant *>(h)->toBool(); }
const char *qtd_qvariant_to_string(void *h, size_t *n) {
    return own(static_cast<QVariant *>(h)->toString().toUtf8(), n);
}

// --- QHash<QString,QString> <-> D string[string] ---------------------------
// (Hand-written instantiation; the generator would emit this per <K,V>, like
//  it already does for QList<T>.)
void *qtd_qhashss_new() { return new HSS(); }
void  qtd_qhashss_insert(void *h, const char *kp, size_t kn, const char *vp, size_t vn) {
    static_cast<HSS *>(h)->insert(QString::fromUtf8(kp, (int) kn),
                                  QString::fromUtf8(vp, (int) vn));
}
int   qtd_qhashss_size(void *h) { return static_cast<HSS *>(h)->size(); }
void  qtd_qhashss_delete(void *h) { delete static_cast<HSS *>(h); }

void *qtd_qhashss_iter_new(void *h) { return new HSSit(static_cast<HSS *>(h)->constBegin()); }
int   qtd_qhashss_iter_valid(void *h, void *it) {
    return *static_cast<HSSit *>(it) != static_cast<HSS *>(h)->constEnd();
}
const char *qtd_qhashss_iter_key(void *it, size_t *n) { return own((*static_cast<HSSit *>(it)).key().toUtf8(), n); }
const char *qtd_qhashss_iter_val(void *it, size_t *n) { return own((*static_cast<HSSit *>(it)).value().toUtf8(), n); }
void  qtd_qhashss_iter_next(void *it) { ++(*static_cast<HSSit *>(it)); }
void  qtd_qhashss_iter_delete(void *it) { delete static_cast<HSSit *>(it); }

// --- QList<int> : accessors that a D random-access range wraps --------------
void *qtd_qlist_int_new()                 { return new QList<int>(); }
void  qtd_qlist_int_append(void *h, int v){ static_cast<QList<int> *>(h)->append(v); }
int   qtd_qlist_int_size(void *h)         { return static_cast<QList<int> *>(h)->size(); }
int   qtd_qlist_int_at(void *h, int i)    { return static_cast<QList<int> *>(h)->at(i); }
void  qtd_qlist_int_delete(void *h)       { delete static_cast<QList<int> *>(h); }

} // extern "C"
