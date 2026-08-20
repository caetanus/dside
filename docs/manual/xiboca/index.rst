..
   SPDX-FileCopyrightText: 2026 Marcelo A Caetano
   SPDX-License-Identifier: BSL-1.0

xiboca
======

xiboca reads a **spec** — one JSON file — and writes D source. It compiles
nothing: the sources it emits are compiled by whatever build you already have.
The spec is therefore the entire user interface, and this part of the manual is
about writing one.

Xiboquinha is a Brazilian drink, cachaça with ginger and honey, and the name is
not arbitrary: a wrapper generator does what a still does. Raw material goes in,
something distilled comes out.

How it works
------------

xiboca parses your headers with **libclang's C API** — the stable one, not
``clang.cindex`` — discovers classes, extracts their public constructors and
methods, maps their types, and emits ``extern(C++)`` D. The emitted modules
mangle straight to the C++ symbols, so there is no per-class C shim to compile
and no wrapper layer between D and the library.

.. code-block:: text

   your headers  ->  libclang  ->  discovery  ->  type mapping  ->  .d + .cpp
                        ^                              ^
                     pkg-config                    the spec's
                     cflags                        ownership keys

What it will not do for you
---------------------------

Two things cannot be inferred from a header and are therefore yours to declare:

**Ownership that moves at a call.** Whether ``addTopLevelItem`` takes ownership
of its argument is a fact about the library's contract, not about its signature.
See :doc:`ownership`.

**Which types are worth binding.** Discovery is filtered — by a path fragment for
a framework, or by ``source_filter`` for your own code. See :doc:`discovery`.

Everything else, including the ABI, the mangling and the container conversions,
comes from parsing.
