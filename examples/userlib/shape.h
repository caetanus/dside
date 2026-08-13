// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
#pragma once
#include <QObject>
#include <QString>
#include <QHash>
#include <QMap>
#include <QVariant>

// A hand-written user Qt class — NOT part of the Qt framework.
class Shape : public QObject {
    Q_OBJECT
public:
    explicit Shape(QObject *parent = nullptr);
    void setSize(int w, int h);
    int area() const;
    QString describe() const;      // returns QString -> D string via conversion
    bool isSquare() const;
    QHash<QString,int> counts() const;      // QHash -> int[string]
    QMap<QString,QString> tags() const;     // QMap  -> string[string]
    QVariant metadata() const;              // QVariant -> QtVariant
    void setMetadata(const QVariant &m);
};

class Circle {                     // a plain (non-QObject) user value type
public:
    Circle();
    explicit Circle(int radius);
    int radius() const;
    double circumference() const;
};
