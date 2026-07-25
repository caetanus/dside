#pragma once
#include <QHash>
#include <QMap>
#include <QSet>
#include <QList>
#include <QStack>
#include <QQueue>
#include <QVector>
#include <QString>
#include <QByteArray>
class QCtrTest {
public:
    virtual ~QCtrTest();
    QHash<QString,QString> hashSS();          // assoc return  -> qhash_str_str
    QMap<QString,int>      mapSI();            // assoc return  -> qmap_str_int
    QSet<QString>          setS();             // set   return  -> qset_str
    QHash<int,QByteArray>  hashIB();           // assoc return  -> qhash_int_bytes
    void takeListI(const QList<int>&);         // seq   param   -> qlist_int
    void takeStackD(const QStack<double>&);    // seq   param   -> qstack_double
    void takeVecB(const QVector<QByteArray>&); // seq   param   -> qlist_bytes (QVector==QList)
    void takeSetS(const QSet<QString>&);       // set   param   -> qset_str
    QMap<QByteArray,QByteArray> mapBB();        // assoc return, BYTES KEY -> immutable(ubyte)[] key
};
