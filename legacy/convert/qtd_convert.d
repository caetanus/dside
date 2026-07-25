// qtd_convert.d — the idiomatic D layer over the raw conversion shim.
// This is the shape the generator will emit alongside each raw binding.
module qtd_convert;

extern (C) nothrow @nogc {
    void*        qtd_qstring_from_utf8(const(char)* p, size_t n);
    const(char)* qtd_qstring_utf8(void* h, size_t* n);
    void         qtd_qstring_delete(void* h);
    void         qtd_free(void* p);

    void*        qtd_qbytearray_from(const(char)* p, size_t n);
    const(char)* qtd_qbytearray_data(void* h, size_t* n);
    void         qtd_qbytearray_delete(void* h);

    void*        qtd_qurl_from(const(char)* p, size_t n);
    const(char)* qtd_qurl_to(void* h, size_t* n);
    void         qtd_qurl_delete(void* h);

    void*        qtd_qvariant_new();
    void*        qtd_qvariant_from_long(long v);
    void*        qtd_qvariant_from_double(double v);
    void*        qtd_qvariant_from_bool(int v);
    void*        qtd_qvariant_from_string(const(char)* p, size_t n);
    void         qtd_qvariant_delete(void* h);
    int          qtd_qvariant_kind(void* h);
    long         qtd_qvariant_to_long(void* h);
    double       qtd_qvariant_to_double(void* h);
    int          qtd_qvariant_to_bool(void* h);
    const(char)* qtd_qvariant_to_string(void* h, size_t* n);

    void* qtd_qlist_int_new();
    void  qtd_qlist_int_append(void* h, int v);
    int   qtd_qlist_int_size(void* h);
    int   qtd_qlist_int_at(void* h, int i);
    void  qtd_qlist_int_delete(void* h);

    void*        qtd_qhashss_new();
    void         qtd_qhashss_insert(void* h, const(char)* kp, size_t kn, const(char)* vp, size_t vn);
    int          qtd_qhashss_size(void* h);
    void         qtd_qhashss_delete(void* h);
    void*        qtd_qhashss_iter_new(void* h);
    int          qtd_qhashss_iter_valid(void* h, void* it);
    const(char)* qtd_qhashss_iter_key(void* it, size_t* n);
    const(char)* qtd_qhashss_iter_val(void* it, size_t* n);
    void         qtd_qhashss_iter_next(void* it);
    void         qtd_qhashss_iter_delete(void* it);
}

// --- QHash<QString,QString> <-> string[string] -----------------------------

/// D associative array -> QHash handle (caller deletes).
void* toQHashSS(string[string] aa) {
    auto h = qtd_qhashss_new();
    foreach (k, v; aa)
        qtd_qhashss_insert(h, k.ptr, k.length, v.ptr, v.length);
    return h;
}

/// QHash handle -> D associative array (borrows the handle).
string[string] fromQHashSS(void* h) {
    string[string] aa;
    auto it = qtd_qhashss_iter_new(h);
    scope (exit) qtd_qhashss_iter_delete(it);
    while (qtd_qhashss_iter_valid(h, it)) {
        size_t kn, vn;
        auto kp = qtd_qhashss_iter_key(it, &kn);
        auto vp = qtd_qhashss_iter_val(it, &vn);
        aa[kp[0 .. kn].idup] = vp[0 .. vn].idup;
        qtd_free(cast(void*) kp);
        qtd_free(cast(void*) vp);
        qtd_qhashss_iter_next(it);
    }
    return aa;
}

// --- QString <-> string ----------------------------------------------------

/// D string -> QString handle (borrowed; delete when done). @nogc: no toStringz.
void* toQString(scope const(char)[] s) @nogc nothrow {
    return qtd_qstring_from_utf8(s.ptr, s.length);
}

/// QString handle -> GC-allocated D string.
string toDString(void* qstr) {
    size_t n;
    auto p = qtd_qstring_utf8(qstr, &n);
    string r = p[0 .. n].idup;
    qtd_free(cast(void*) p);
    return r;
}

/// Like toDString but also deletes the (owned) QString handle. Used for
/// container elements, where each QList<QString> element is a fresh handle.
string toDStringOwned(void* qstr) {
    string r = toDString(qstr);
    qtd_qstring_delete(qstr);
    return r;
}

// --- QByteArray <-> string -------------------------------------------------
void* toQByteArray(scope const(char)[] s) @nogc nothrow { return qtd_qbytearray_from(s.ptr, s.length); }
string fromQByteArray(void* h) {
    size_t n; auto p = qtd_qbytearray_data(h, &n);
    string r = p[0 .. n].idup; qtd_free(cast(void*) p); return r;
}
string fromQByteArrayOwned(void* h) { auto r = fromQByteArray(h); qtd_qbytearray_delete(h); return r; }

// --- QUrl <-> string -------------------------------------------------------
void* toQUrl(scope const(char)[] s) @nogc nothrow { return qtd_qurl_from(s.ptr, s.length); }
string fromQUrl(void* h) {
    size_t n; auto p = qtd_qurl_to(h, &n);
    string r = p[0 .. n].idup; qtd_free(cast(void*) p); return r;
}
string fromQUrlOwned(void* h) { auto r = fromQUrl(h); qtd_qurl_delete(h); return r; }

// --- QList<int> as a D random-access range ---------------------------------
// Borrows the list handle; the handle must outlive the range. Once it's a D
// range, foreach / std.algorithm (.map/.filter/.sum/...) all just work.
struct QListIntRange {
    private void* h;
    private int i, n;

    this(void* handle) @nogc nothrow {
        h = handle; i = 0; n = qtd_qlist_int_size(handle);
    }
    @property bool empty() const @nogc nothrow { return i >= n; }
    @property int front() const @nogc nothrow { return qtd_qlist_int_at(cast(void*) h, i); }
    void popFront() @nogc nothrow { ++i; }
    @property size_t length() const @nogc nothrow { return cast(size_t)(n - i); }
    int opIndex(size_t idx) const @nogc nothrow { return qtd_qlist_int_at(cast(void*) h, cast(int)(i + idx)); }
}

// --- QVariant <-> D QtVariant ----------------------------------------------
enum QtVariantKind { invalid, boolean, integer, floating, text, other }

/// Idiomatic D wrapper over QVariant (owns the handle; call dispose()).
struct QtVariant {
    void* handle;

    static QtVariant from(long v)   { return QtVariant(qtd_qvariant_from_long(v)); }
    static QtVariant from(double v) { return QtVariant(qtd_qvariant_from_double(v)); }
    static QtVariant from(bool v)   { return QtVariant(qtd_qvariant_from_bool(v)); }
    static QtVariant from(string v) { return QtVariant(qtd_qvariant_from_string(v.ptr, v.length)); }

    QtVariantKind kind() const { return cast(QtVariantKind) qtd_qvariant_kind(cast(void*) handle); }
    bool   isNull()   const { return kind == QtVariantKind.invalid; }
    long   toLong()   const { return qtd_qvariant_to_long(cast(void*) handle); }
    double toDouble() const { return qtd_qvariant_to_double(cast(void*) handle); }
    bool   toBool()   const { return qtd_qvariant_to_bool(cast(void*) handle) != 0; }
    string toStr()    const {
        size_t n; auto p = qtd_qvariant_to_string(cast(void*) handle, &n);
        string r = p[0 .. n].idup; qtd_free(cast(void*) p); return r;
    }
    void dispose() { qtd_qvariant_delete(handle); }
}
