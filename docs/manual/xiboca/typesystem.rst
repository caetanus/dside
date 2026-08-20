..
   SPDX-FileCopyrightText: 2026 Marcelo A Caetano
   SPDX-License-Identifier: BSL-1.0

Typesystem rules
================

Some facts about a C++ library are not in its headers. PySide/shiboken records
several of them in XML typesystem files, and xiboca borrows a **small, explicitly
bounded subset of that XML as data** — it does not fork shiboken and it is not a
general typesystem parser.

What is extracted
-----------------

Four patterns, by regular expression, from every file matching
``typesystem_glob`` in ``typesystem_dir``:

.. list-table::
   :header-rows: 1
   :widths: 34 66

   * - Pattern
     - Effect
   * - ``<rejection class="X"/>``
     - Skip the class entirely. Counted as ``shiboken-rejected`` in
       ``coverage.txt``.
   * - ``<rejection class="X" function-name="f">``
     - Skip that one method of that class.
   * - ``<object-type name="X">``
     - X has identity, not value. Returning it **by value** becomes
       ``Unmappable`` with the reason ``object-type by value``, instead of being
       heap-copied — copying a QObject-derived type is not a thing you can do.
   * - ``<value-type name="X">``
     - X is copyable. Recorded, and used to tell the two populations apart.

Nothing else is read. Ownership, renaming, injected code, argument modifications
— all of shiboken's real vocabulary — are ignored. That is why ownership lives in
:doc:`ownership` as spec keys audited by hand: it is a decision, and this file
does not pretend to derive it.

.. code-block:: json

   "typesystem_dir": "/usr/share/PySide6/typesystems",
   "typesystem_glob": "typesystem_core*.xml"

What it would change here, measured
-----------------------------------

.. warning::

   **No spec in this repository sets** ``typesystem_dir``. The loader, the four
   patterns and the three call sites that consult ``RULES`` are all present and
   reachable, and none of them ever fires, because with no spec enabling it the
   rule tables are empty and every lookup misses. A feature whose effect is
   invisible is indistinguishable from one that does not work — the same shape as
   a gate that verifies nothing and reports OK.

So the useful question is what turning it on would do. Measured on 2026-08-20
against PySide6's shipped typesystems (102 files) and this project's QtWidgets
binding (467 classes, 7873 symbols):

.. list-table::
   :header-rows: 1
   :widths: 60 40

   * - 
     - Count
   * - Classes PySide rejects that we bind
     - **0**
   * - Methods PySide rejects that we bind
     - **5**
   * - Classes PySide marks ``object-type`` that we bind
     - **341**

The first row is the interesting one: **nothing this project binds is a class
shiboken refuses**. The 29 rejected classes are Python-specific concerns that do
not arise here. The five methods are worth looking at individually rather than
adopting wholesale — a rejection in a Python binding is evidence, not a verdict,
about a D one.

The 341 object-types looked like the rule that would actually bite: a
QObject-derived type returned by value would be caught earlier and by name.

It does not bite. Measured on 2026-08-20 by generating the whole QtWidgets binding
twice, once with ``typesystem_dir`` pointed at PySide6's typesystems and once
without:

.. code-block:: text

   coverage-manifest.tsv     8428 rows, 0 lines differ
   emitted D modules         818 vs 818, 0 modules differ

**Enabling the rules changes nothing.** Not a class, not a symbol, not a fate, not
a line of emitted D. The generator's own analysis already reaches every conclusion
these rules would contribute: a record type that cannot be copied is caught by
looking at the record, not by being told.

The honest position
-------------------

The feature is inert on this binding, and now that is measured rather than
suspected. It is kept for one reason: it costs four regular expressions, and if a
future Qt or a third-party library contains a class that libclang describes
plausibly and shiboken knows to be a trap, this is the channel through which that
knowledge arrives without inventing a rule of our own.

But it must not be described as load-bearing. Whoever reads ``coverage.txt`` and
sees ``0 shiboken-rejected`` should know that the number would be 0 with the rules
switched off as well.
