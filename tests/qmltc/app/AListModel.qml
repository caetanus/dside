// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A LIST MODEL AND A DELEGATE READING IT. Qt's Controls never declare a ListModel — they take one
// from outside — so every path here (ListElement rows, `model.<role>` inside a delegate, a count
// that a binding outside the view reads back) is untouched by the styles corpus.
import QtQuick
Item {
    width: 200; height: 90
    ListModel {
        id: rows
        ListElement { label: "one";   weight: 10 }
        ListElement { label: "two";   weight: 20 }
        ListElement { label: "three"; weight: 30 }
    }
    property int total: 0
    Column {
        Repeater {
            model: rows
            delegate: Text { text: label + ":" + weight; height: 20 }
        }
    }
    Text { y: 70; text: "rows=" + rows.count }
}
