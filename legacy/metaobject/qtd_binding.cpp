// qtd_binding.cpp — BindingManager C support, QtCore-only.
//
// Split out of qtd_meta.cpp (which pulls QtQml) so ANY generated QObject binding
// can link it without dragging in QML. Provides the destroyed() hook, ownership
// query, and a couple of plain-QObject helpers used by the stress test.
#include <QObject>

extern "C" {

typedef void (*QtdDestroyedFn)(void *cptr);
static QtdDestroyedFn g_onDestroyed = nullptr;

// Install the single D-side callback invoked whenever a tracked QObject dies.
void qtd_set_destroyed_hook(QtdDestroyedFn fn) { g_onDestroyed = fn; }

// Route obj->destroyed() to the global hook. The connection dies with the object,
// and destroyed() forwards the dying pointer as the BindingManager key.
void qtd_track_destroyed(void *obj) {
    QObject *o = static_cast<QObject *>(obj);
    QObject::connect(o, &QObject::destroyed, [](QObject *dead) {
        if (g_onDestroyed) g_onDestroyed(static_cast<void *>(dead));
    });
}

// A parented QObject is owned by C++ (Qt deletes it with its parent), so D must
// not delete it. Mirrors Shiboken's hasOwnership flipping false on setParent.
int qtd_has_parent(void *obj) {
    return static_cast<QObject *>(obj)->parent() != nullptr ? 1 : 0;
}

// Plain heap QObject helpers — exercise the general (non-meta) wrapper path.
void *qtd_make_qobject() { return new QObject(); }
void  qtd_qobject_delete(void *obj) { delete static_cast<QObject *>(obj); }
void  qtd_qobject_set_parent(void *child, void *parent) {
    static_cast<QObject *>(child)->setParent(static_cast<QObject *>(parent));
}

} // extern "C"
