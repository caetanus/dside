<!--
SPDX-FileCopyrightText: 2026 Marcelo A Caetano
SPDX-License-Identifier: BSL-1.0
-->
# The application-shaped corpus

Qt's own Controls are a narrow, disciplined dialect: `T.Something` roots, declared properties,
almost no loose JS, and every type imported from Qt. A gate that only walks them measures the
compiler against the QML its authors wrote for a style engine, not against the QML people write.

These documents are the shapes that dialect does not have — list models and delegates, `Loader`,
real JavaScript with loops and arrays and objects, states and transitions, signals crossing
document boundaries, one document instantiating another from the same directory, anchors.

Each one is renderable STANDALONE on purpose. That is the whole reason this corpus can be judged
at all: a real application's document usually is not (`Bitcoin.qml` needs the bar, its data and
its C++ context, and the engine draws nothing for it alone), which is why pointing the gate at one
reported 61 of 78 documents unjudgeable. Self-contained documents make the per-document criterion
apply again — at the cost of not proving anything about the context an application supplies.
