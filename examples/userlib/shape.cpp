// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
//
// The implementation behind shape.h. It exists so the example is not merely
// GENERATED but COMPILED, LINKED and RUN by `xiboca-quickstart` — a binding that
// emits cleanly and does not link is the failure this example is here to catch.
#include "shape.h"

Shape::Shape(QObject *parent) : QObject(parent) {}

void Shape::setSize(int a, int b) { w = a; h = b; }
int Shape::area() const { return w * h; }
QString Shape::describe() const { return QString("%1x%2").arg(w).arg(h); }
bool Shape::isSquare() const { return w == h; }

QHash<QString, int> Shape::counts() const {
    QHash<QString, int> r;
    r["width"] = w;
    r["height"] = h;
    return r;
}

QMap<QString, QString> Shape::tags() const {
    QMap<QString, QString> r;
    r["kind"] = isSquare() ? QStringLiteral("square") : QStringLiteral("rect");
    return r;
}

QVariant Shape::metadata() const { return meta; }
void Shape::setMetadata(const QVariant &m) { meta = m; }

Circle::Circle() {}
Circle::Circle(int radius) : r(radius) {}
int Circle::radius() const { return r; }
double Circle::circumference() const { return 2.0 * 3.14159265358979 * r; }
