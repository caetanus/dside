..
   SPDX-FileCopyrightText: 2026 Marcelo A Caetano
   SPDX-License-Identifier: BSL-1.0

What comes out
==============

Into ``out_dir``:

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - File
     - What it is
   * - ``<d_package>/*.d``
     - One module per class or enum, at a path matching its ``module`` name.
   * - ``cxxrt.d``, ``holder.d``
     - The runtime, copied in — the emitted binding is self-contained.
   * - ``*.cpp``
     - Shims and trampolines, to be compiled and linked alongside.
   * - ``coverage.txt``
     - The human summary.
   * - ``coverage-manifest.tsv``
     - One row per symbol, with its fate.

Reading coverage.txt
--------------------

.. code-block:: text

   671 classes emitted, 0 shiboken-rejected.
   per-symbol manifest: coverage-manifest.tsv, 8428 rows. fate breakdown:
     bound          4479
     inherited      1487
     pure-virtual    190
     shimmed        1046
     signal          501
     unmapped-type   725

``unmapped-type`` is the only line that means *you did not get this*. Each of
those rows names the type that stopped it, so "what is missing" is a ``grep``
rather than a guess. ``inherited`` is not a gap: it means the method arrives
through a base class, which for a second base means an explicit cast such as
``asQPaintDevice()``.

The symbol check
----------------

xiboca refuses to bind a method whose mangled symbol is provably absent from the
libraries being linked. It runs ``nm -D --defined-only`` over the ``.so`` files
that ``pkg-config --libs`` and ``libs`` name — searching the ``-L`` directories
they give, then ``/usr/lib``, ``/usr/lib64`` and ``/usr/local/lib`` — and drops
what it cannot find. Binding a declaration whose definition does not exist
produces a link error at the far end of the pipeline, where it is hardest to read.

For your own library this would be exactly wrong, since your ``.so`` is not in
``pkg_config`` and nothing of yours would be found. So the check is **per class
and self-disabling**: it applies to a class only if at least one of that class's
non-inline public methods is already in the symbol table. A class from a library
xiboca knows nothing about has no methods there, the check never turns on, and
everything is bound.

.. warning::

   The consequence is worth knowing: the check protects against mistakes on the
   library's side and is **silent** about yours. If one of your own classes fails
   to link, the missing definition is in your ``.cpp``, and xiboca could not have
   warned you.

Failure is loud
---------------

If a header cannot be found, libclang returns a translation unit with fatal
diagnostics and *zero* classes. xiboca refuses to emit rather than writing a
binding with nothing in it. That failure mode was live once — a spec whose include
path had stopped resolving produced "0 classes" and exit 0 — and closing it is why
a wrong ``include_paths`` now fails loudly instead of quietly.
