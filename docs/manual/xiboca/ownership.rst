..
   SPDX-FileCopyrightText: 2026 Marcelo A Caetano
   SPDX-License-Identifier: BSL-1.0

Ownership
=========

These are the keys that cannot be inferred from a header, and they are the reason
a Qt spec is longer than a spec for your own code. Whether a method takes
ownership of its argument is a fact about the library's *contract*, not about its
signature, so it is declared and audited against the library's documentation —
never guessed.

.. list-table::
   :header-rows: 1
   :widths: 22 78

   * - Key
     - Meaning
   * - ``transfer_in``
     - ``"QTreeWidget::addTopLevelItem/0"`` — argument 0 of that method **takes**
       ownership. The suffix is the argument index.
   * - ``transfer_out``
     - The call **gives** ownership back to the caller.
   * - ``disposable``
     - This type has an owner-managed lifetime and may be destroyed explicitly.
   * - ``ctor_parents``
     - Which constructor arguments act as parents. ``[]`` means none of them do,
       which is a statement, not an omission.

For your own code you usually need none of these — until you write a method that
takes ownership of a raw pointer, at which point you need ``transfer_in`` for the
same reason Qt does.

``no_transfer`` belongs to the gate, not the generator
------------------------------------------------------

xiboca never reads ``no_transfer``. It is consumed by ``tests/ownership-gate.sh``,
which walks every generated method taking a ``disposable`` type and fails the
build on any that appears in none of the three lists.

So ``no_transfer`` changes no emitted code. It records that a method was
**examined and found harmless**. Without it, an unclassified method and a
checked-and-harmless one are indistinguishable — which is the difference between
a gap and a decision, and the reason "not a transfer" is written down as a finding
rather than left as an absence.

What the emitted binding does with this
---------------------------------------

With ``wrapper`` enabled, the emitted code carries the *parenting-pins* lifetime
layer: a pointer the library returns is **borrowed** by default, a parented child
is pinned by a GC root so it outlives any dropped D reference, and an unparented
wrapper that is collected calls ``deleteLater`` because it owned the object. The
default is borrowed on purpose — assuming ownership of something you did not
allocate is a double free, while assuming the opposite is merely a leak.

The consumer's side of that model is documented with the binding rather than with
the generator; see :doc:`/dside/using-the-binding`.
