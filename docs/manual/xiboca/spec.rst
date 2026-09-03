..
   SPDX-FileCopyrightText: 2026 Marcelo A Caetano
   SPDX-License-Identifier: BSL-1.0

Spec reference
==============

Every key xiboca reads. This page is compared against the generator's source by
the ``docs-spec-keys`` gate, in both directions: a key the code reads and this
page omits fails the build, and so does a key documented here that nothing reads.

Required
--------

.. list-table::
   :header-rows: 1
   :widths: 22 78

   * - Key
     - Meaning
   * - ``pkg_config``
     - Space-separated modules to parse and link against. Supplies the compile
       flags and the symbol table.
   * - ``abi``
     - Must be ``"cxx"``. The C-ABI shim emitter was removed; any other value is
       a hard error, refused once before anything is parsed.
   * - ``out_dir``
     - Where to write. Resolved against the spec file.
   * - ``d_package``
     - The D package name. Dots become directories under ``out_dir``, so
       ``qt.widgets`` writes ``qt/widgets/*.d`` and ``import qt.widgets.qwidget``
       resolves against ``-I<out_dir>``.

Discovery
---------

.. list-table::
   :header-rows: 1
   :widths: 22 78

   * - Key
     - Meaning
   * - ``discover_module``
     - An umbrella header to include, e.g. ``QtWidgets``.
   * - ``headers``
     - Extra headers to scan. Combines with ``discover_module``.
   * - ``qt_marker``
     - Path fragment identifying framework headers. Default ``/qt6/``. A class is
       kept if its name starts with ``Q`` and it was declared under this path.
   * - ``source_filter``
     - Path fragment for *your own code* mode: keep any class declared under it,
       whatever it is named. Overrides the ``Q``-prefix rule.
   * - ``include_paths``
     - Extra ``-I`` directories. Relative entries resolve against the spec file.
   * - ``classes``
     - Legacy fallback: an explicit list of ``{"include": ...}`` entries, used
       only when neither ``discover_module`` nor ``headers`` is given.

Toolchain location
------------------

.. list-table::
   :header-rows: 1
   :widths: 22 78

   * - Key
     - Meaning
   * - ``pkg_config_path``
     - Directories prepended to ``PKG_CONFIG_PATH``: *which installation*, as
       opposed to which modules. Relative entries resolve against the spec file.
   * - ``cflags``
     - Raw compile flags, for a library that ships no ``.pc``.
   * - ``libs``
     - Raw link flags, same case. Also feeds the symbol scan.
   * - ``resource_dir``
     - The clang whose BUILTIN headers to parse with — ``stddef.h``, ``stdint.h``
       and the rest, which live beside a compiler rather than in a sysroot.
       Defaults to this machine's (``clang -print-resource-dir``), which is what
       every desktop spec wants. A CROSS spec names the target toolchain's: an
       Android parse with the host's answered ``unknown type name 'int32_t'``
       twenty times, from a ``<stdint.h>`` that resolved and defined nothing.

Emission
--------

.. list-table::
   :header-rows: 1
   :widths: 22 78

   * - Key
     - Meaning
   * - ``wrapper``
     - GC wrapper mode: emit the parenting-pins lifetime layer.
   * - ``exceptions``
     - Translate C++ exceptions into D ones across the boundary.
   * - ``subclass``
     - Classes you intend to derive from in D. Emits virtual trampolines.
   * - ``subclass_derived``
     - The same, for types reached as derived rather than named explicitly.
   * - ``qmltypes``
     - Also emit a ``.qmltypes`` description for QML tooling.
   * - ``docs_dir``
     - Also emit an API reference: one reStructuredText page per class, plus an
       index, into this directory. The pages carry the D signatures as emitted,
       what each class inherits, and every symbol that is **not** bound with the
       reason the generator recorded. Resolved against the spec file.
   * - ``qt_version``
     - A label. Carried into ``coverage.txt`` and used to select Qt5-vs-Qt6
       emission.

Ownership
---------

Covered in :doc:`ownership`, which is where the reasoning belongs: ``transfer_in``,
``transfer_out``, ``disposable``, ``ctor_parents``.

Typesystem
----------

.. list-table::
   :header-rows: 1
   :widths: 22 78

   * - Key
     - Meaning
   * - ``typesystem_dir``
     - Directory of PySide/shiboken typesystem XML to read **as data**.
   * - ``typesystem_glob``
     - Which files in it. Default ``typesystem_*.xml``.

The bounded subset that is read, and what enabling it would change, are in
:doc:`typesystem`.

Comments
--------

Keys beginning with ``_`` are ignored by the generator, and the shipped specs use
them to record *why* a decision was made where the decision lives:

.. code-block:: json

   "_spinbox_not_bindable_reason": "QQuickSpinBox/QQuickDoubleSpinBox are NOT
     bindable, measured 2026-08-02: adding their headers DOES map them, and then
     every subclass fails ..."

Four such keys exist today. They are the answer to "why is this absent" written
next to the absence, rather than in a commit message nobody will find.
