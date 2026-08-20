..
   SPDX-FileCopyrightText: 2026 Marcelo A Caetano
   SPDX-License-Identifier: BSL-1.0

Troubleshooting
===============

.. list-table::
   :header-rows: 1
   :widths: 38 62

   * - Symptom
     - Cause
   * - ``only abi:cxx is supported``, exit 1
     - The spec is missing ``"abi": "cxx"``.
   * - Fatal diagnostics, no output
     - A header did not resolve — check ``include_paths`` and ``pkg_config``.
   * - 0 classes, no diagnostics
     - ``qt_marker`` or ``source_filter`` matches nothing. The parse succeeded and
       discovery kept nothing.
   * - A method you wanted is ``unmapped-type``
     - Its signature uses a type not yet mapped; the manifest row names it.
   * - A method you wanted is ``inherited``
     - It is there, reached through a base class — possibly a second base, which
       means an explicit cast.
   * - Link error on a library symbol
     - The symbol check was off for that class, because none of its siblings were
       in the ``.so`` either. Check that ``pkg_config`` names the right library.
   * - Link error on **your** symbol
     - Your definition is missing. The check cannot see your library and did not
       warn you.
   * - ``moc`` rejects Qt 6 headers with an ``#error``
     - ``moc`` on ``PATH`` is Qt 5's. Use the one under
       ``pkg-config --variable=libexecdir Qt6Core``.
   * - ``qmetaobjectbuilder_p.h`` not found
     - ``qtdmoc.cpp`` needs Qt's private headers; add
       ``-I$INC/QtCore/$VER -I$INC/QtCore/$VER/QtCore``.
