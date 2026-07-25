// qtd_holder.cpp — C support for the D wrapper lifetime layer. QtCore-only.
//
// The identity map lives HERE (C++ side) on purpose: the D GC does not scan C++
// memory, so a D wrapper stored here is NOT pinned by it — the map is naturally
// "weak". Pinning of parented children is done separately on the D side. Verified:
// a D object referenced only from this map is collectable.
#include <QObject>
#include <QCoreApplication>
#include <unordered_map>

extern "C" {

typedef void (*QtdDestroyedFn)(void *cptr);
static QtdDestroyedFn g_onDestroyed = nullptr;

// cptr -> D wrapper (an opaque void*). Weak from D's point of view. HEAP-allocated and
// never freed on purpose: a D GC finalizer can run during process teardown AFTER C++ static
// destructors, so a static map object would be a use-after-free (destruction-order fiasco).
static std::unordered_map<void *, void *> &g_wrappers() {
    static std::unordered_map<void *, void *> *m = new std::unordered_map<void *, void *>();
    return *m;
}

void qtd_holder_set_destroyed_hook(QtdDestroyedFn fn) { g_onDestroyed = fn; }

// Route obj->destroyed() to the D hook; the connection dies with the object and
// forwards the dying pointer as the map key.
void qtd_holder_track(void *obj) {
    QObject *o = static_cast<QObject *>(obj);
    QObject::connect(o, &QObject::destroyed, [](QObject *dead) {
        if (g_onDestroyed) g_onDestroyed(static_cast<void *>(dead));
    });
}

// A parented QObject is owned by Qt (deleted with its parent) — D must not delete it.
int  qtd_holder_has_parent(void *obj) { return static_cast<QObject *>(obj)->parent() != nullptr ? 1 : 0; }
void qtd_holder_delete_later(void *obj) { static_cast<QObject *>(obj)->deleteLater(); }
// The QApplication/QCoreApplication singleton must NEVER be finalize-deleted (deleteLater'ing
// it tears down the platform plugin under Qt's feet). The user owns it for the app's lifetime.
int  qtd_holder_is_app(void *obj) { return obj == QCoreApplication::instance() ? 1 : 0; }

// identity map
void  qtd_holder_reg(void *cptr, void *wrapper) { g_wrappers()[cptr] = wrapper; }
void *qtd_holder_find(void *cptr) { auto it = g_wrappers().find(cptr); return it == g_wrappers().end() ? nullptr : it->second; }
void  qtd_holder_unreg(void *cptr) { g_wrappers().erase(cptr); }

} // extern "C"
