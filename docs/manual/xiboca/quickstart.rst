..
   SPDX-FileCopyrightText: 2026 Marcelo A Caetano
   SPDX-License-Identifier: BSL-1.0

Quickstart
==========

Binding a C++ library that is not Qt, end to end. Every step below is executed by
the ``xiboca-quickstart`` build target, and the program's output is compared
against a golden file — so this page cannot quietly stop being true.

The library
-----------

``examples/userlib/shape.h`` declares a ``QObject`` subclass and a plain value
type. Nothing about it is special:

.. code-block:: cpp

   class Shape : public QObject {
       Q_OBJECT
   public:
       explicit Shape(QObject *parent = nullptr);
       void setSize(int w, int h);
       int area() const;
       QString describe() const;
       QHash<QString,int> counts() const;
   private:
       int w = 0, h = 0;
   };

   class Circle {                 // not a QObject at all
   public:
       explicit Circle(int radius);
       int radius() const;
       double circumference() const;
   };

The spec
--------

.. code-block:: json

   {
     "qt_version": "6.11-userlib",
     "pkg_config": "Qt6Core",
     "abi": "cxx",
     "out_dir": "../generated/userlib",
     "d_package": "userlib",
     "headers": ["shape.h"],
     "source_filter": "examples/userlib",
     "include_paths": ["../examples/userlib"]
   }

That is ``generator/spec_userlib.json``, complete. ``headers`` plus
``source_filter`` is the *your own code* discovery mode — see :doc:`discovery`.

Generate
--------

.. code-block:: sh

   cd xiboca && dub build            # -> ./xiboca
   ./xiboca ../generator/spec_userlib.json

.. code-block:: text

   discovered 2 classes in your headers
   done: 2 classes emitted (0 shiboken-rejected), 24 D bindings -> generated/userlib

What the D side looks like
--------------------------

.. code-block:: d

   extern (C++) class Shape : QObject {
       ubyte[8] __pad;                                    // the C++ object's own fields
       pragma(mangle, "_ZN5Shape7setSizeEii") final void setSize(int a0, int a1);
       pragma(mangle, "_ZNK5Shape4areaEv")    final int area() const;
       extern (D) final int[string] counts() const { ... }  // QHash<QString,int>
       static Shape __make(QObject a0 = null) { ... }
   }

Three things to notice:

* the methods mangle **directly** to your C++ symbols — there is no shim between;
* ``__pad`` is the size of your object's own fields, so D allocates a C++-sized
  object rather than a D-sized one;
* ``QHash<QString,int>`` arrives as a D associative array, with the C++ call
  hidden behind an ``extern(D)`` wrapper.

Use it
------

.. code-block:: d

   import userlib.shape, userlib.circle;
   import std.stdio;

   void main() {
       auto s = Shape.__make(null);   // allocates with C++ new, then calls your ctor
       s.setSize(4, 4);
       writeln("area      = ", s.area());
       writeln("describe  = ", s.describe().toString);
       writeln("counts    = ", s.counts());

       auto c = Circle.__make(7);
       writefln("circle    = r%d, circumference %.3f", c.radius(), c.circumference());
   }

Build and run
-------------

.. code-block:: sh

   # your code, plus moc because Shape has Q_OBJECT
   /usr/lib/qt6/moc shape.h -o moc_shape.cpp
   clang++ -std=c++17 -fPIC -c shape.cpp moc_shape.cpp $(pkg-config --cflags Qt6Core)

   # the generated shims; qtdmoc.cpp additionally needs Qt's private headers
   clang++ -std=c++17 -fPIC -c gen/*.cpp -I. -Ipath/to/your/headers \
       $(pkg-config --cflags Qt6Core) -I$INC/QtCore/$VER -I$INC/QtCore/$VER/QtCore

   # the D side, then link
   ldc2 -c -I gen -od=dobj gen/userlib/*.d gen/cxxrt.d gen/qtmoc.d app.d
   ldc2 -of=app dobj/*.o *.o -L-lstdc++ $(pkg-config --libs Qt6Core | sed 's/-l/-L-l/g')

.. code-block:: text

   area      = 16
   describe  = 4x4
   isSquare  = true
   counts    = ["height":4, "width":4]
   tags      = ["kind":"square"]
   circle    = r7, circumference 43.982

.. warning::

   Use **Qt 6's** ``moc``, not whatever ``moc`` is on ``PATH``. On a machine with
   both Qt versions installed the plain name usually resolves to Qt 5's, which
   refuses Qt 6 headers with a ``#error`` that reads like a header problem. The
   build target finds it via ``pkg-config --variable=libexecdir Qt6Core``.

.. note::

   ``qtdmoc.cpp`` is the only generated file that needs Qt's **private** headers —
   it is the layer that lets a D class declare its own signals and slots. The
   other emitted ``.cpp`` files compile with ordinary flags.
