#include <QObject>
#include <QCoreApplication>
extern "C" {
void* ht_make() { return new QObject(); }
void  ht_setparent(void* c, void* p) { static_cast<QObject*>(c)->setParent(static_cast<QObject*>(p)); }
void  ht_delete(void* o) { delete static_cast<QObject*>(o); }
void* ht_app() { static int argc=0; return new QCoreApplication(argc, nullptr); }
void  ht_process() { QCoreApplication::processEvents(); QCoreApplication::sendPostedEvents(nullptr, 0); QCoreApplication::processEvents(); }
}
