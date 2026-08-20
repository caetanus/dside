..
   SPDX-FileCopyrightText: 2026 Marcelo A Caetano
   SPDX-License-Identifier: BSL-1.0

DSide
=====

Qt for D: pure ``extern(C++)`` bindings, generated rather than hand-written.

Two products live here, and they answer different questions:

**DSide** is the binding a D developer *consumes* to write a Qt application —
windows, ownership, signals and slots.

**xiboca** is the generator that *produces* a binding — from a Qt module, from a
third-party Qt library, or from your own C++.

.. toctree::
   :maxdepth: 2
   :caption: xiboca — generating a binding

   xiboca/index
   xiboca/quickstart
   xiboca/discovery
   xiboca/spec
   xiboca/ownership
   xiboca/output
   xiboca/troubleshooting

.. toctree::
   :maxdepth: 2
   :caption: DSide — using a binding

   dside/using-the-binding
   dside/reading-qt-docs

.. note::

   The API reference under *API reference (generated)* is produced by xiboca from
   the binding itself and is not in the repository — it appears when the build has
   generated one. See ``docs/documentation-plan.md``.

What this manual promises
-------------------------

Every factual claim here is checked by the build:

* ``docs-sphinx`` builds these pages with warnings as errors, so a broken
  reference or a page missing from the table of contents fails;
* ``docs-spec-keys`` compares the spec reference against the keys the generator
  actually reads, in **both** directions — an undocumented key fails, and so does
  a documented key nothing reads;
* ``xiboca-quickstart`` generates, compiles, links and runs the example on
  :doc:`xiboca/quickstart`, then diffs its output against a golden file.

That is not decoration. On 2026-08-14 every coverage figure in this project's
README was wrong in four different ways at once, and the fix was a gate rather
than proofreading. A documented claim is a claim under test.
