..
   SPDX-FileCopyrightText: 2026 Marcelo A Caetano
   SPDX-License-Identifier: BSL-1.0

Reading Qt's documentation from D
=================================

Qt's own documentation is the best description of what its classes *do*, and it
applies here almost unchanged — because the binding is generated as-is. Measured
on ``QWidget``: **217 methods, of which 5 carry a spelling of ours**, and 36
overloads preserved as D overloads (``resize(int,int)`` and ``resize(QSize)``
side by side, exactly as in C++).

So the useful thing to learn is not a translation table. It is five rules and one
percentage.

The five rules
--------------

**1. Signals become** ``connect<Name>``. A Qt signal is not a method you call; it
is a method that takes a D delegate, generated per signal so the compiler checks
the signature:

.. code-block:: d

   timer.connectTimeout(() { writeln("tick"); });

A mismatched slot is a compile error rather than a runtime warning on stderr,
which is what ``QObject::connect`` with strings gives you in C++.

**2. A second base is reached by** ``as<Base>()``. ``QWidget`` inherits ``width()``
from ``QPaintDevice``, its second base, so it is ``w.asQPaintDevice().width()``.
Multiple inheritance is surfaced as an explicit cast instead of being flattened —
flattening would hide which base a method really comes from.

**3. Constructors are** ``new`` **, with the parent as an argument.**
``new QLabel(parent)``. Where a constructor is not auto-bound, the emitted class
carries a ``__make`` factory instead; ``QApplication`` is the one type whose
``(int&, char**, int)`` constructor you declare yourself.

**4. Qt containers arrive as D's own** where the mapping is exact:
``QHash<QString,int>`` as ``int[string]``, ``QMap<QString,QString>`` as
``string[string]``. The method name is unchanged, only the return type is D's.

**5. Strings convert both ways.** ``qstr("text")`` builds a ``QString``;
``.toString`` reads one back.

The one percentage
------------------

**8.6% of symbols are not there.** In the QtWidgets binding: 8428 symbols, of
which 725 are ``unmapped-type`` — a type in the signature has no D mapping yet.
Those are not hidden. Each class page in this reference lists them by name with
the reason the generator recorded, and the same information is in
``coverage-manifest.tsv`` beside the binding.

The rest of the breakdown is not missing, only reached differently:

.. list-table::
   :header-rows: 1
   :widths: 20 12 68

   * - Fate
     - Share
     - What it means for you
   * - ``bound``
     - 53.1%
     - Call it by its Qt name.
   * - ``inherited``
     - 17.6%
     - It arrives through a base — possibly a second one, so rule 2 applies.
   * - ``shimmed``
     - 12.4%
     - Same name; the call goes through a generated trampoline.
   * - ``unmapped-type``
     - 8.6%
     - Not available. The reason is on the class page.
   * - ``signal``
     - 5.9%
     - Rule 1.
   * - ``pure-virtual``
     - 2.3%
     - Override it in a subclass; there is nothing to call.

Where Qt's documentation does **not** apply
-------------------------------------------

One area, and it is a large one: **moc**. Qt documents a build step that runs
``moc`` over headers containing ``Q_OBJECT`` and compiles its output. DSide has no
such step for your classes. A D class declares ``@QObject``, ``@Slot`` and
``Signal!T``, and its meta-object is built at compile time by CTFE and attached at
construction. Everything Qt's documentation says about *using* the meta-object —
``connect`` by name, introspection, QML visibility — remains true; everything it
says about *producing* it does not apply.

The other area is ownership. Qt's rules about parent-child deletion still hold,
but what a dropped D reference means is ours to define, and it is defined in
:doc:`using-the-binding`.
