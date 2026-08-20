..
   SPDX-FileCopyrightText: 2026 Marcelo A Caetano
   SPDX-License-Identifier: BSL-1.0

Pointing xiboca at a Qt it has never seen
=========================================

The claim this project is built around is that a new Qt version should cost
almost nothing: point the generator at it, and what breaks should be small and
mechanical. PyQt/SIP is the reference — each new Qt arrived essentially free,
because version knowledge lived in **data** rather than in code.

This page is the procedure, and it is written to be falsifiable. It cannot be run
against a Qt 7 that does not exist, so what follows is anchored to the one
version change the project performs on every build: **Qt 5.15 and Qt 6.11 from the
same generator**.

What a version change actually costs, measured
----------------------------------------------

Seven keys are shared between the Qt5 and Qt6 specs for the same library —
``abi``, ``d_package``, ``discover_module``, ``out_dir``, ``pkg_config``,
``qt_version``, ``subclass`` — and of the differences, four are locations:

.. code-block:: text

   pkg_config    Qt6Widgets   ->  Qt5Widgets
   out_dir       .../qt-6.11  ->  .../qt-5.15
   qt_version    6.11         ->  5.15
   qt_marker     (default)    ->  /qt/       # where that Qt's headers live

Nothing about *classes*, *methods* or *mangling* is version-conditional: the
discovery inputs and the subclass list are identical across the pair.

.. warning::

   The rest of the difference is **not** a version difference, and saying so
   matters more than the tidy claim it replaces. The Qt5 spec also lacks
   ``wrapper``, ``exceptions``, and every ownership key — ``ctor_parents``,
   ``disposable``, ``transfer_in``, ``transfer_out``, ``no_transfer``. The Qt5
   parity target is therefore a *narrower configuration*, not the same
   configuration on another release. What the pair proves is that discovery,
   mapping, mangling and the value-type ABI carry across a major version. It does
   **not** exercise the GC wrapper, the exception layer or the ownership
   declarations against Qt5, so those parts of the claim rest on argument rather
   than on this measurement.

In the generator itself, **16 lines out of 5211** mention the version at all, and
every one is about the same thing — the value-type ABI:

.. code-block:: text

   emit_cxx.d   11 lines   QVector/QStack have a distinct layout from QList in Qt5;
                           QString and QByteArray have different internal runtimes
   emit.d        5 lines   derive `qt5` from qt_version and pass it down

That is the honest size of "supporting another major version" for this
architecture: a handful of ABI facts, isolated behind one boolean, plus four
strings in a spec.

The procedure
-------------

**1. Record the release before trusting anything about it.**
Add a ``verified-for`` row to ``docs/qt-license-matrix.tsv`` only after reading
that release's licensing, and a row per module you intend to link. The gate
refuses to judge a release it does not record — deliberately, because applying
another version's answers is how a wrong licence claim gets made. This is the one
step that is reading rather than engineering, and it cannot be skipped.

**2. Copy a spec and change the four keys above.**
Point ``pkg_config_path`` at the new installation if it is not the system one, so
that the choice is in the spec rather than in the environment.

**3. Generate, and read the diagnostics rather than the output.**
A header that does not resolve is a hard error; a spec whose ``qt_marker`` matches
nothing emits zero classes. Both fail loudly. What you want from this run is the
``coverage.txt`` breakdown and, in particular, the ``unmapped-type`` count with the
``why`` column of the manifest beside it.

**4. Diff the manifest against the previous version's.**
This is the measurement that answers "what broke". ``manifest-gate`` already does
it between builds; against a new Qt it is the same comparison with a bigger
delta. Methods that vanished, methods that changed fate, classes that stopped
being discovered — each is a row, not a guess.

**5. Compile and link, on both compilers.**
The project requires ldc2 **and** dmd parity. A version change that works on one
is not a version change that works.

**6. Run the differential suite.**
For QML, ``qmltc-d`` is judged against the engine of that same Qt: byte-identical
frame plus every property of every named object. A new Qt brings a new engine, so
the oracle moves with it and the comparison stays honest.

What would count as the architecture failing
--------------------------------------------

Stating this in advance is the point of the page. The claim is falsified if, for a
new Qt:

* the generator needs a version conditional that is **not** about the value-type
  ABI — that would mean version knowledge has leaked into code that should be
  data;
* the ownership or typesystem declarations need rewriting, rather than extending
  for genuinely new classes;
* the mangling produced by libclang stops matching, on a platform where it matched
  before.

None of these has happened between 5.15 and 6.11. If one happens for the next
version, it is not a porting task — it is the design being wrong, and the honest
response is to say so here.

The known gap
-------------

``pkg_config_path``, ``cflags`` and ``libs`` reach the **generator** and not the
build: the compile, the link and the licence gates still resolve Qt through
pkg-config independently. Generating against one Qt while linking against another
is exactly the ABI mismatch this design is sensitive to, so until those keys flow
through the build as well, a non-default installation must be selected by the
environment too. This is written here rather than discovered later.
