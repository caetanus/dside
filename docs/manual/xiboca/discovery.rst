..
   SPDX-FileCopyrightText: 2026 Marcelo A Caetano
   SPDX-License-Identifier: BSL-1.0

What gets bound: discovery
==========================

xiboca parses one translation unit and keeps a subset of what it finds. There are
two ways to say which subset, and they **combine**.

A Qt module
-----------

.. code-block:: json

   "discover_module": "QtWidgets",
   "pkg_config": "Qt6Widgets",
   "qt_marker": "/qt6/"

``discover_module`` becomes ``#include <QtWidgets>``, and everything that umbrella
header pulls in is scanned. What is *kept* is decided by ``qt_marker``, a path
fragment that defaults to ``/qt6/``: a class belongs to Qt if its name starts with
``Q`` **and** it was declared under that path.

A third-party Qt library
------------------------

Nothing in xiboca is Qt-specific beyond those defaults. A library shipping headers
and a ``.pc`` file is bound the same way:

.. code-block:: json

   "pkg_config": "Qt6Charts",
   "discover_module": "QtCharts",
   "qt_marker": "/QtCharts/"

Two things have to be right:

* ``pkg_config`` must name the library itself, not only its dependencies — it
  supplies the parse flags *and* the symbol table;
* ``qt_marker`` must match where the headers actually live, or discovery keeps
  nothing.

.. note::

   Whether such a library may be linked into a product is a separate question with
   its own gate: ``docs/qt-license-matrix.tsv`` is an allowlist, and a module
   absent from it is refused deliberately.

Your own C++
------------

.. code-block:: json

   "headers": ["shape.h"],
   "source_filter": "examples/userlib",
   "include_paths": ["../examples/userlib"]

``source_filter`` switches discovery into *your-own-code* mode: any class whose
declaring file path contains that fragment is kept, whatever it is called. The
``Q``-prefix rule does not apply, so ``Circle`` is bound exactly like ``QWidget``.

Combining both
--------------

A module **plus** extra headers are parsed as one translation unit. That is how
the Quick binding reaches the private element headers that declare
``QQuickRectangle`` while still discovering everything ``<QtQuick>`` brings in.

Relative paths resolve against the **spec file**, not the working directory, so a
spec behaves the same run from the repository root or from ``generator/``.

Choosing which Qt
-----------------

``pkg_config`` says *which modules*. It does not say *which installation* — that
used to come from whatever ``PKG_CONFIG_PATH`` happened to hold, invisible in the
spec and therefore unrecorded, so the same spec could bind against a different Qt
on a different machine and nothing said so.

.. code-block:: json

   "pkg_config_path": ["/opt/qt/6.8.1/gcc_64/lib/pkgconfig"]

Listed directories are **prepended**, so the spec's choice wins over the
environment's.

.. warning::

   The build must be told the same thing. xiboca only emits sources; the compile,
   the link and the licence gates resolve Qt through pkg-config independently.
   Generating against one Qt and linking against another is exactly the ABI
   mismatch this design is sensitive to. Making the build read these keys is not
   done yet.

A library with no ``.pc``
-------------------------

VTK, OpenCASCADE and anything else that is CMake-config-only cannot be named by
``pkg_config``, so give its flags directly:

.. code-block:: json

   "pkg_config": "Qt6Core",
   "cflags": ["-I/usr/include/vtk-9.3"],
   "libs":   ["-L/usr/lib/vtk-9.3", "-lvtkCommonCore-9.3"],
   "headers": ["/usr/include/vtk-9.3/vtkPolyData.h"],
   "source_filter": "vtk-9.3"

``cflags`` reaches the parse; ``libs`` reaches the symbol scan described in
:doc:`output`, and is what a build needs in order to link.
