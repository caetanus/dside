<!--
SPDX-FileCopyrightText: 2026 Marcelo A Caetano
SPDX-License-Identifier: BSL-1.0
-->
# Documentation plan — DSide and xiboca

Status: **proposed**, 2026-08-18. Nothing here is done yet.

The project acquired two names this week, and that is not cosmetic: it split one
thing into two products with two audiences that share almost no questions.

- **DSide** is what a D developer *consumes* to write a Qt application. Their
  questions are "how do I show a window", "who owns this pointer", "why does my
  slot not fire".
- **xiboca** is what someone *runs* to produce a binding. Their questions are
  "what goes in a spec", "how do I bind my own C++ library", "Qt 7 came out, what
  breaks".

Today there is one 420-line README that answers a bit of both and neither
completely, and a `docs/` whose largest file by far is a 6304-line engineering
journal. That is not a criticism of what exists — the journal is the reason the
hard parts are recoverable — but a journal is a record, not documentation.

## What is measurably missing

Counted on 2026-08-18, not estimated:

| Gap | Evidence |
|---|---|
| **The spec format is documented nowhere** | `emit.d` reads **19** spec keys (`abi`, `ctor_parents`, `discover_module`, `disposable`, `exceptions`, `headers`, `include_paths`, `pkg_config`, `qmltypes`, `qt_marker`, `source_filter`, `subclass`, `subclass_derived`, `transfer_in`, `transfer_out`, `typesystem_dir`, `typesystem_glob`, `wrapper`, plus `out_dir`/`d_package`/`qt_version` handled elsewhere). `docs/uic-spec.md` is about uic, a different file format. A reader's only reference is 25 example specs and the source. |
| **The typesystem subset has no reference** | `xiboca/README.md` gives it 12 lines under "Rules from shiboken — a small regex subset". It is the mechanism by which ownership, wrapping and exceptions are decided. |
| **No consumer-facing DSide documentation** | README §"Using it from your own project" is the whole of it. Nothing on memory ownership, signal/slot from D, or what to do when a type is missing. |
| **No answer to the north-star question** | "Point it at Qt 7 and see what breaks" is the project's stated purpose, and no document says how to do it. |

## The principle this plan is built on

**A documented claim is a claim under test.** This repository already refuses to
let numbers rot: `tests/docs-numbers.sh` exists because on 2026-08-14 every
coverage figure in `README.md` and `docs/qmltc-d.md` was wrong in four different
ways at once, and the fix was not proofreading but a gate that compares the
documented numbers against what the build counted.

Every phase below therefore ships **documentation plus the gate that keeps it
true**. A doc with no gate is a doc that will be wrong within two months, and the
project has already measured exactly that.

## Phase 1 — split the entry points

Three documents, each with one audience.

- `README.md` becomes the **project** page: what DSide and xiboca are, how they
  relate, and where to go. It stops trying to be a manual.
- `docs/dside/` — the binding consumer.
- `docs/xiboca/` — the generator operator.

**Exit criterion:** every section of the current README has moved to exactly one
of the three, or has been deleted deliberately. No section is duplicated.

## Phase 2 — the spec reference (xiboca)

The spec is xiboca's user interface. It gets a reference page: every key, its
type, its default, what it does, and a real example taken from a spec that the
matrix actually builds.

**Gate — `docs-spec-keys`:** the union of keys read by `xiboca/*.d` must equal the
union of keys documented, both ways. A key added to the generator and not
documented fails; a documented key the generator never reads fails too. This is
the same shape as `docs-numbers`: the source of truth is the code, and the
document is compared against it.

## Phase 3 — the typesystem reference (xiboca)

The regex subset, ownership rules (`transfer_in`, `transfer_out`, `disposable`,
`no_transfer`), `wrapper`, `subclass`, and the exception layer. Each rule
documented with the input that triggers it and the output it produces.

**Gate — `docs-typesystem`:** every rule documented must appear in the typesystem
files the matrix consumes, and every rule kind the parser accepts must be
documented. Same two-way comparison.

## Phase 4 — DSide consumer guide

In the order a person actually hits the questions:

1. install and link (this exists, needs moving);
2. a first window, compiled;
3. **memory and ownership** — the borrowed-by-default rule, parenting, what
   happens on `destroyed()`. This is where a binding hurts people, and this
   project has a designed answer that is currently only in commit messages;
4. signals and slots from D, including custom ones via the meta-object channel;
5. QML, pointing at `docs/qmltc-d.md` rather than restating it;
6. what to do when something is missing — how to tell "not bound yet" from "bound
   and broken", and how to add it.

**Gate — `docs-examples`:** every code block marked as compilable in these pages
is extracted and built by the matrix. A binding change that breaks an example
breaks the build, which is the only way an example stays correct.

## Phase 5 — the Qt 7 procedure (xiboca)

The document the project's purpose implies: point xiboca at a Qt version it has
never seen and write down what happens. It must state what is expected to be
free, what is expected to need a line of data, and what would count as the
architecture failing.

This one **cannot be gated by a Qt 7 that does not exist**, and saying so is part
of the document. What can be gated is the claim underneath it: the Qt5/Qt6 dual
target already exercises "same generator, two Qt versions", and the procedure must
be written so that running it against Qt5 today produces the documented result.

## Phase 6 — reference material that follows from the above

API listing per module, generated from what the binding actually exports rather
than written by hand. Lower priority: it is the part a reader can get from the
source, and the parts they cannot get from the source are Phases 2–4.

## Order, and why

Phases 2 and 3 come first because **xiboca's documentation gap is the one that
blocks other people from using the project at all** — a generator whose input
format is undocumented can only be operated by its author. Phase 4 is next
because it is the largest audience. Phase 5 is the one that proves the thesis, and
it is deliberately last: it should be written after the reference pages exist, so
it can point at them instead of restating them.

## What this plan does not do

It does not propose a documentation site, a theme, or a generator toolchain. Those
are choices to make once there is enough prose to justify them. Markdown in the
repository, gated by the matrix, is where the content should be proven first.
