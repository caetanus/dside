<!--
SPDX-FileCopyrightText: 2026 Marcelo A Caetano
SPDX-License-Identifier: BSL-1.0
-->
# Contributing

## Licensing of contributions

Contributions are accepted under the **Boost Software License 1.0**, the project's license (see
`LICENSE`). There is no CLA and no copyright assignment: you keep your copyright, and you license
your contribution under the same terms as the rest of the project.

Sign off each commit with the [Developer Certificate of Origin](https://developercertificate.org/):

```sh
git commit -s
```

`-s` appends `Signed-off-by: Your Name <your@email>`. That line is the statement quoted in the DCO —
that you wrote the change, or have the right to submit it under BSL-1.0.

## What must never enter the tree

Nothing whose terms you cannot state. Concretely:

- **No copied implementation.** Similar names, matching API declarations and calls into Qt are not
  copying; taking an upstream *implementation* is, and it keeps the upstream license. This matters
  most for the C++ trampolines: the project's license reasoning depends on them being original work.
  If you adapted something, say so in the commit and add the upstream header.
- **No file without provenance.** A test fixture from somewhere else needs its origin, upstream
  revision and license expression recorded in `THIRD-PARTY.md` before it is committed. A `.ui` or
  `.qml` with no header is exactly the problem `docs/licensing-plan.md` Phase 1 exists to undo.
- **No GPL-only dependency in anything that ships.** GPL-only Qt modules may be used by tests that
  publish no binary, and the `license-no-gpl-product` gate enforces the boundary. Adding one to a
  product spec is meant to fail the build with a licensing diagnostic, not a link error.

New project-authored files carry an SPDX header:

```
SPDX-FileCopyrightText: <year> <your name>
SPDX-License-Identifier: BSL-1.0
```

Files that cannot carry comments are covered by `REUSE.toml` instead. Never edit an upstream header
to match ours — where upstream stated its terms, that statement is the truth.

## Working in this repository

- `./build` runs the matrix. It is expected to be green; a red build is the answer, not the obstacle.
- Gates fail closed by design. If one blocks you, the intended response is to change the code or to
  change the recorded baseline **with a written reason** — never to loosen the check quietly.
- `tests/expected-fails.json` is the inventory of known gaps and documented risks. An entry that
  stops being true must be removed or narrowed; `expected-fails-run` reports both directions.
- Comments explain *why*, and are expected to cite the measurement that justified the code. This
  repository's comments carry a lot of history on purpose.
