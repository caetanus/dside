// qtd_meta.cpp — native meta-object machinery (no moc).
//
// A C++ trampoline `QtdObject : QObject` carries a QMetaObject built at runtime
// with QMetaObjectBuilder from a description supplied by D (properties, signals,
// slots). qt_metacall dispatches slot invocations and property reads/writes back
// into D via callbacks. Same approach as qmetaobject-rs / PySide — the C++ side
// owns the QObject vtable so D never has to.
#include <QObject>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QVariant>
#include <private/qmetaobjectbuilder_p.h>
#include <cstdlib>

typedef void (*QtdSlotFn)(void *dself, int id, void **args);
typedef void (*QtdRWFn)(void *dself, int id, void *arg);
// Called from ~QtdObject when C++ (deleteLater / parent-delete / engine teardown)
// destroys the object. This is the moment PySide/Shiboken invalidates the wrapper
// (validCppObject=0) and BindingManager::releaseWrapper drops it. On the D side it
// releases the GC pin so the backing object becomes collectable again.
typedef void (*QtdDtorFn)(void *dself);

class QtdObject : public QObject {
public:
    const QMetaObject *m_mo;
    void *m_dself;
    QtdSlotFn m_slot;
    QtdRWFn m_read, m_write;
    QtdDtorFn m_dtor;

    QtdObject(const QMetaObject *mo, void *dself, QtdSlotFn s, QtdRWFn r, QtdRWFn w, QtdDtorFn d)
        : m_mo(mo), m_dself(dself), m_slot(s), m_read(r), m_write(w), m_dtor(d) {}

    // Qt destroyed us: notify D (release the GC pin, invalidate the wrapper), then
    // free the runtime-built QMetaObject (toMetaObject() returns a malloc'd block).
    ~QtdObject() override {
        if (m_dtor) m_dtor(m_dself);
        if (m_mo) free(const_cast<QMetaObject *>(m_mo));
    }

    const QMetaObject *metaObject() const override { return m_mo; }
    void *qt_metacast(const char *n) override { return QObject::qt_metacast(n); }

    int qt_metacall(QMetaObject::Call c, int id, void **a) override {
        id = QObject::qt_metacall(c, id, a);
        if (id < 0) return id;
        if (c == QMetaObject::InvokeMetaMethod) {
            int n = m_mo->methodCount() - m_mo->methodOffset();
            if (id < n) m_slot(m_dself, id, a);
            return id - n;
        }
        if (c == QMetaObject::ReadProperty) {
            int n = m_mo->propertyCount() - m_mo->propertyOffset();
            if (id < n) m_read(m_dself, id, a[0]);
            return id - n;
        }
        if (c == QMetaObject::WriteProperty) {
            int n = m_mo->propertyCount() - m_mo->propertyOffset();
            if (id < n) m_write(m_dself, id, a[0]);
            return id - n;
        }
        return id;
    }
};

extern "C" {

// --- meta-object description -> live object --------------------------------
void *qtd_mob_new(const char *className) {
    QMetaObjectBuilder *b = new QMetaObjectBuilder();
    b->setClassName(className);
    b->setSuperClass(&QObject::staticMetaObject);
    return b;
}
int qtd_mob_add_signal(void *b, const char *sig) {
    return static_cast<QMetaObjectBuilder *>(b)->addSignal(sig).index();
}
int qtd_mob_add_slot(void *b, const char *sig) {
    return static_cast<QMetaObjectBuilder *>(b)->addSlot(sig).index();
}
int qtd_mob_add_property(void *b, const char *name, const char *type, int notifyIdx) {
    QMetaObjectBuilder *mb = static_cast<QMetaObjectBuilder *>(b);
    QMetaPropertyBuilder p = mb->addProperty(name, type);
    p.setReadable(true);
    p.setWritable(true);
    if (notifyIdx >= 0) p.setNotifySignal(mb->method(notifyIdx));
    return p.index();
}
void *qtd_mob_create_object(void *b, void *dself, QtdSlotFn s, QtdRWFn r, QtdRWFn w,
                            QtdDtorFn d) {
    QMetaObjectBuilder *mb = static_cast<QMetaObjectBuilder *>(b);
    QMetaObject *mo = mb->toMetaObject();
    delete mb;
    return new QtdObject(mo, dself, s, r, w, d);
}

// Explicit delete (mirrors what deleteLater/parent-delete do, but synchronously).
// Runs ~QtdObject -> the D dtor callback -> GC pin released + wrapper invalidated.
void qtd_object_delete(void *obj) { delete static_cast<QtdObject *>(obj); }

// NOTE: the BindingManager C support (qtd_set_destroyed_hook / qtd_track_destroyed
// / qtd_has_parent / plain-QObject helpers) lives in qtd_binding.cpp — QtCore-only,
// so generated bindings can link it without dragging in QtQml.

void qtd_object_emit(void *obj, int localSignalIndex, void **args) {
    QtdObject *o = static_cast<QtdObject *>(obj);
    QMetaObject::activate(o, o->m_mo, localSignalIndex, args);
}

// Emit on the MAIN event-loop stack, not the caller's. Required when emitting
// from a vibe fiber: QML/V4 re-evaluates bindings as JS, and V4's stack guard is
// calibrated to the main thread stack — evaluating on a fiber stack silently
// fails. A queued invocation defers activate() to the loop (main stack).
void qtd_object_emit_queued(void *obj, int localSignalIndex) {
    QtdObject *o = static_cast<QtdObject *>(obj);
    QMetaObject::invokeMethod(o, [o, localSignalIndex]() {
        QMetaObject::activate(o, o->m_mo, localSignalIndex, nullptr);
    }, Qt::QueuedConnection);
}

// --- QML wiring / introspection helpers ------------------------------------
void qtd_ctx_set_object(void *engine, const char *name, void *obj) {
    static_cast<QQmlApplicationEngine *>(engine)->rootContext()->setContextProperty(
        name, static_cast<QObject *>(obj));
}
int qtd_obj_read_int(void *obj, const char *prop) {
    return static_cast<QObject *>(obj)->property(prop).toInt();
}
void qtd_obj_invoke(void *obj, const char *method) {
    QMetaObject::invokeMethod(static_cast<QObject *>(obj), method);
}

} // extern "C"
