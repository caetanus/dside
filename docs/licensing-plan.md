<!--
SPDX-FileCopyrightText: 2026 Marcelo A Caetano
SPDX-License-Identifier: BSL-1.0
-->
# Licensing plan

Status: **adopted — implementation in progress**  
Adopted: **2026-08-13**, by the copyright holder, who asked for this plan to be applied.  
Last reviewed: **2026-08-17**

Progress against the phases is tracked in the checkboxes below; each is ticked only when its exit
criterion is met and verifiable, not when the work is started. Two phases cannot be completed by
implementation alone and say so where they appear: Phase 7 is a review by counsel. Phase 1 was in
that list until 2026-08-14 — it needed a decision about test corpora — and it is no longer: the
corpora were resolved by establishing their provenance, and what is left inside it is a preference
about vendoring rather than a blocker. It is recorded that way in Phase 1 itself, not summarised
away here.

This document is the licensing and distribution plan for `qt-dlang-gen`, its generated Qt bindings
for D, its runtime, and its tools. It records the intended result, the work required before the
first public release, and the checks that must remain true afterward.

It is an engineering compliance plan, not legal advice. The first Windows release should be
reviewed by counsel familiar with open-source licensing using the actual release archive, its SBOM,
and the Qt source bundle—not only this document.

## Decision

The proposed project license is the **Boost Software License 1.0 (`BSL-1.0`)** for all code written
for this project, including:

- the D binding generator;
- the runtime written in D and C++;
- generated D bindings and generated C++ shims/trampolines;
- `qmltc-d`, `uic-d`, `qrc-d`, `lupdate-d`, and the other project tools;
- original tests, examples, build logic, and documentation.

Third-party material keeps its upstream license. A root `LICENSE` does not and cannot relicense Qt,
Qt test data, libclang, DUB dependencies, or any other third-party work.

The supported open-source distribution model is:

1. project code under BSL-1.0;
2. Qt dynamically linked under the license offered for each selected module, normally LGPLv3;
3. no GPL-only Qt library in an installed binding, runtime, tool bundle, or downstream application;
4. GPL-only test dependencies isolated from product artifacts;
5. exact notices, corresponding sources, and replacement rights supplied by the distributor of a
   Windows application that bundles Qt.

This decision was adopted on 2026-08-13. What follows is the record of what has been implemented
against it, and what has not.

Here and everywhere in this plan, **BSL-1.0 means Boost Software License 1.0**. It does not mean the
unrelated Business Source License, whose SPDX identifier is `BUSL-1.1`.

## Why BSL-1.0

The binding is infrastructure. It should be usable by proprietary, permissively licensed, LGPL,
and GPL applications without imposing a new copyleft boundary of its own. BSL-1.0 is short,
permissive, SPDX-listed, OSI-approved, and familiar in the D ecosystem; `libdparse`, already used by
this repository, also uses it.

The project's C++ trampolines should not be licensed LGPL merely because they call Qt. They are
project-authored adapter code, and the installed package currently incorporates them into static
archives. Putting those archives under LGPL would create avoidable relinking obligations for every
downstream application. BSL-1.0 lets the trampolines be linked statically while Qt itself remains a
replaceable dynamic dependency.

This conclusion depends on the trampolines being original implementations. Any file or substantial
implementation copied or adapted from Qt must retain the applicable upstream terms or be rewritten
independently. Similar names, API declarations, and calls into Qt do not by themselves justify
copying an upstream implementation.

## Artifact and license matrix

| Artifact | Intended license | Distributed? | Rule |
|---|---|---:|---|
| `generator-d` / `gend` | BSL-1.0 | yes | Must not embed third-party implementation text in its output |
| generated `.d` declarations and wrappers | BSL-1.0 output grant | yes | Generated header must state the policy and provenance |
| generated C++ shims and trampolines | BSL-1.0 output grant | yes | May be archived and statically linked into the application |
| `runtime/holder` and `runtime/qtmoc` | BSL-1.0 | yes | Copied into generated bindings; license must travel with every package |
| `qmltc-d` | BSL-1.0 | optionally | Current target links QtQml and QtCore, not QtQmlCompiler |
| other project tools | BSL-1.0 | optionally | Dependencies and invoked Qt tools remain separately licensed |
| project-authored tests/examples/docs | BSL-1.0 | source repository | Must carry SPDX coverage |
| `qtd_qmltypes_check` | GPL-3.0-only boundary | tests only | Links the GPL-only Qt Qml Compiler module; never package it |
| Qt shared libraries and plugins | upstream Qt terms | by app distributor | Preserve upstream notices and satisfy each module's obligations |
| Qt WebEngine/Chromium payload | upstream mixed terms | optional profile | Requires its own notice/source inventory |
| external test corpora | upstream terms | preferably no | Fetch at test time or replace with original fixtures |

“BSL-1.0 output grant” means that the copyright holder grants BSL-1.0 for generator-authored text
and templates appearing in the output. It does not change the license or ownership of the user's
input files, Qt, or other input material. The generated-output policy must say this explicitly.

## Qt boundary

Qt has not abandoned the LGPL. Qt 6 is available under commercial and open-source terms; most
modules used here are available under LGPLv3, while a defined set of modules is GPL-only for
open-source users. The authoritative module list for the selected Qt release is Qt's
[Qt Licensing](https://doc.qt.io/qt-6/licensing.html) page and, for Qt 6.8 onward, its SPDX SBOM.

The product may use LGPL Qt only through shared libraries. Static Qt builds are outside the
supported community-distribution profile. This restriction applies to Qt itself, not to the
project's BSL-licensed archives.

### Initially allowed Qt modules

The release allowlist may include, after verification against the exact Qt release:

- Qt Core;
- Qt GUI;
- Qt Widgets;
- Qt Qml;
- Qt Qml Models;
- Qt Quick;
- Qt Quick Controls and the style/runtime libraries actually selected;
- Qt WebEngine under the separate WebEngine distribution profile.

An allowlist entry is not permanent. Every supported Qt minor version must be checked independently,
including its private headers and third-party components.

### GPL-only denylist

The product dependency graph must reject GPL-only Qt modules unless the whole affected artifact is
deliberately released under compatible GPL terms or Qt is used under suitable commercial terms.
At the time of this plan, the denylist includes at least:

- Qt Canvas Painter;
- Qt CoAP;
- Qt Graphs;
- Qt GRPC;
- Qt HTTP Server;
- Qt Lottie Animation;
- Qt MQTT;
- Qt Network Authorization;
- Qt Qml Compiler;
- Qt Quick 3D;
- Qt Quick 3D Physics;
- Qt Quick Timeline;
- Qt Virtual Keyboard;
- Qt Wayland Compositor.

The CI gate must derive or verify this list against the precise Qt version used for a release. The
list in this document is a floor, not the source of truth.

### Private Qt headers

The generator, runtime, and `qmltc-d` use private Qt headers. Private API is an ABI and maintenance
risk, but “private” does not itself mean GPL. Each included file must be checked using the SPDX
expression in the exact source release from which the development package was built. A release
inventory must record:

- header path;
- Qt repository, version, and commit/tag;
- SPDX license expression found in the file;
- consuming source/target;
- whether the header contributes inline or template implementation to a distributed binary.

Unknown, commercial-only, or GPL-only private headers fail the product build until reviewed. Header
availability in a package manager is not evidence of license compatibility.

## The Qt Qml Compiler exception in this repository

`qmltc-d` itself currently includes QtQml's private parser headers and links QtQml plus QtCore. It
does **not** link `Qt6QmlCompiler` in its normal build target.

The `.qmltypes` validator in `tests/qml/qtd_qmltypes_check.cpp` is different: its build target links
`Qt6QmlCompiler`, which Qt lists as GPL-only for open-source users. It must become an explicit GPL
test island:

1. move it under a clearly named test-only boundary such as `tests/gpl/qmltypes-validator/`;
2. mark the validator source `SPDX-License-Identifier: GPL-3.0-only`;
3. ensure its target is absent from `binding-core`, install, package, and release targets;
4. never upload its executable as a CI or release artifact;
5. add a package gate that rejects `Qt6QmlCompiler` and the validator by name and by imported
   library;
6. document that enabling this test requires a GPL-compatible local test environment.

Running a separate GPL tool during a build does not, merely by execution, relicense unrelated
output. Linking a distributed executable with a GPL-only library is the relevant boundary here.
Generated output must still be checked to ensure it contains no copied GPL implementation.

## Existing third-party material that blocks publication

`THIRD-PARTY.md` is the current inventory. Two vendored corpora must be resolved before declaring
the repository publishable.

### `tests/qmltc/cpptypes/`

This directory contains 42 files copied from Qt's qmltc tests. Upstream source files declare
`LicenseRef-Qt-Commercial OR GPL-3.0-only`. They do not enter the installed binding, but publishing
the Git repository distributes them.

Required remedy:

1. remove the vendored upstream files from the project distribution;
2. fetch or locate the exact `qtdeclarative` source tree only when the extended tests are requested;
3. pin an upstream tag/commit and verify a recorded checksum;
4. make absence visible as `SKIP (external GPL corpus unavailable)`, never silent success;
5. exclude fetched sources, derived objects, and test executables from source and binary artifacts;
6. record upstream path, revision, license, retrieval procedure, and test purpose in
   `THIRD-PARTY.md`.

Fetching is preferred to rewriting because the independent upstream corpus tests that the generator
was not tailored only to project-authored fixtures.

### `tests/uic/corpus/`

The directory has 60 `.ui` files attributed generally to Qt but without complete provenance. At the
time of this plan, 13 contain legacy Qt license blocks and 47 contain no copyright, SPDX identifier,
or Qt license block. Their names indicate multiple upstream areas whose licensing differs.

Required remedy:

1. classify every UIC behavior the corpus exercises;
2. write a smaller original fixture for each behavior;
3. retain only fixtures demonstrably written for this project;
4. if any upstream fixture must remain, identify its exact repository path and revision and preserve
   its license verbatim;
5. update goldens so functional coverage does not depend on unresolved provenance;
6. delete the unprovenanced copies from the distribution.

The repository must not infer permission from a missing header. “No license recorded” is not a
permissive license.

### Material read at test time

Qt Quick Controls documents from an installed Qt and PySide's `libsample` from a separately obtained
source tree are not copied into the repository or installed package. Keep this property. CI may use
them under their own terms, but release staging must prove that none of their sources or derived test
objects entered an artifact.

## Required repository files

Before publication, add:

```text
LICENSE                         # BSL-1.0 and scope statement
LICENSES/BSL-1.0.txt
LICENSES/GPL-3.0-only.txt
LICENSES/LGPL-3.0-only.txt
LICENSES/LGPL-2.1-only.txt      # needed by profiles such as WebEngine where applicable
LICENSES/BSD-3-Clause.txt       # Qt examples or retained material, if applicable
LICENSES/Apache-2.0.txt         # third-party payload, if applicable
LICENSES/LLVM-exception.txt     # libclang distribution, if applicable
<name>.license sidecars (no path map — see Phase 2)
CONTRIBUTING.md
docs/licensing.md               # concise user-facing policy after this plan is executed  [DONE]
docs/distributing-qt.md         # instructions for application distributors
```

Only include a license text when the repository or a shipped artifact actually needs it. The final
set should be generated from the completed inventory, not copied blindly from this proposal.

The root `LICENSE` must state that BSL-1.0 applies to project-authored material except where a file's
SPDX identifier or `THIRD-PARTY.md` says otherwise.

## SPDX policy

Project-authored source files should carry:

```text
SPDX-FileCopyrightText: 2026 Marcelo A Caetano
SPDX-License-Identifier: BSL-1.0
```

Use the comment syntax of the file format. Files that cannot carry comments must be covered by
a `<name>.license` sidecar. Do not overwrite upstream headers; add accurate
metadata only when it does not contradict upstream notices.

The repository currently has one author in Git history. Before adopting the license, confirm that
the named copyright holder owns the work and that no unrecorded employer, client, or contributor
claim applies.

Future contributions should use Developer Certificate of Origin sign-off. A CLA is unnecessary
unless the project later needs proprietary dual licensing or copyright assignment.

## Generated-output policy

Every generated `.d` and `.cpp` file must begin with a stable notice such as:

```text
// Generated by qt-dlang-gen. Do not edit; regenerate.
// Generator-authored portions are offered under BSL-1.0.
// SPDX-License-Identifier: BSL-1.0
// Input and referenced APIs remain subject to their own rights and licenses.
```

The generator documentation must state:

- users keep whatever rights they hold in their input specs, headers, QML, and `.ui` files;
- the project grants BSL-1.0 for its templates and other project-authored output text;
- generation does not grant rights in third-party inputs;
- the user must independently comply with the Qt modules and other libraries selected;
- generated bindings may be used in closed-source applications when the selected Qt distribution
  model permits it;
- no guarantee is made that arbitrary input is safe to redistribute.

The generator should emit provenance alongside the binding: generator revision, Qt version, module
list, input-spec digest, and license policy revision. This belongs in both the source header and a
machine-readable manifest.

## DUB package metadata

Add `"license": "BSL-1.0"` to:

- the root `dub.json`;
- `generator-d/dub.json`;
- `runtime/dub.json`;
- `tools/lupdate/dub.json`;
- every later subpackage;
- the installed binding package generated by `tests/install.sh`.

Every published package must include `LICENSE`, its applicable third-party notices, the generated
provenance manifest, and a link to the distribution guide. Declaring a license in DUB is metadata;
it does not replace shipping the actual license or resolving vendored files.

The package test must unpack the final archive and validate the archive itself. Inspecting the source
checkout is insufficient.

## Windows application distribution profile

The binding package can be BSL-1.0 and link its own archives statically. Qt must remain dynamically
linked in the supported LGPL profile. An application distributor bundling Qt DLLs must, for the exact
version shipped:

1. use shared Qt libraries and plugins;
2. permit the user to replace those libraries with compatible modified builds;
3. avoid a loader, signature policy, installer, or device lock that prevents running a replaced
   LGPL library;
4. provide prominent notice that Qt is used and identify the applicable license;
5. include the complete relevant LGPL and GPL license texts;
6. ensure the application EULA does not prohibit reverse engineering needed to debug modifications
   to the LGPL components;
7. provide complete corresponding source for the exact Qt libraries shipped, including local
   changes and build scripts, or a valid written offer and retrieval instructions;
8. keep that source or offer under the distributor's control—a link to qt.io alone is not enough;
9. provide installation/replacement instructions sufficient to run the application with a modified
   compatible Qt library;
10. inventory every Qt DLL, QML plugin, image/platform plugin, compiler runtime, and other shared
    component actually shipped;
11. preserve all third-party notices delivered with that Qt build;
12. verify the terms of the intended store or delivery channel do not add restrictions that conflict
    with LGPL rights.

The Qt Company's own summaries are useful operational references:

- [Obligations of the GPL and LGPL](https://www.qt.io/development/open-source-lgpl-obligations)
- [Qt Open Source Licensing FAQ](https://www.qt.io/faq/qt-open-source-licensing)

The license texts and legal review control if a summary differs from them.

### WebEngine profile

Qt WebEngine is permitted only through a separate packaging profile. Its Qt-specific code and
Chromium payload have additional licenses and notices, including LGPLv2.1 components. A WebEngine
release must use the exact notice bundle and source obligations of the selected Qt build. See
[Qt WebEngine Licensing](https://doc.qt.io/qt-6/qtwebengine-licensing.html).

Do not advertise the ordinary Widgets/QML notice bundle as sufficient for WebEngine.

## CI and release gates

The following gates must be mandatory for a release:

### `license-reuse`

- run `reuse lint`;
- fail on an unlicensed tracked file;
- fail on a missing required license text;
- allow explicit generated/build exclusions only when documented.

### `license-provenance`

- compare tracked third-party paths with `THIRD-PARTY.md`;
- reject unresolved Qt/PySide copyright markers;
- reject external files without an origin, revision, and license expression;
- confirm that runtime files copied by the generator are byte-identical to their recorded sources.

### `license-generated`

- generate every binding family used for release;
- require the generated-output notice and SPDX expression in every emitted source;
- require generator revision, Qt version, and module list in the manifest;
- scan output for known upstream copyright and license markers.

### `license-package`

- build and unpack the exact DUB/release package;
- require BSL metadata, license, notices, and provenance manifest;
- reject `tests/`, external corpora, test objects, and validator binaries;
- reject absolute build paths and accidental source-tree copies.

### `license-no-gpl-product`

- reject known GPL-only Qt module names in product build metadata;
- inspect ELF `DT_NEEDED`, Mach-O load commands where applicable, and PE/COFF imports;
- reject `Qt6QmlCompiler` and the GPL validator in every installed or release artifact;
- allow GPL dependencies only in explicitly test-only jobs that publish no binaries.

### `license-qt-inventory`

- record the exact Qt version and source revision;
- record requested modules and actually imported shared libraries;
- compare the module license map with the release allowlist;
- inventory private headers and their per-file SPDX expressions;
- retain the Qt SPDX SBOM when provided.

### `license-windows-bundle`

- inspect the staged Windows ZIP/installer, not merely link flags;
- verify that every bundled DLL/plugin has a notice and source entry;
- verify absence of static Qt libraries;
- verify source-bundle URL and digest;
- verify replacement instructions on a clean Windows VM;
- ensure Qt DLL replacement is technically possible.

### `license-sbom`

- emit an SPDX SBOM for each release artifact;
- include project revision, generator revision, Qt version, DUB dependencies, compiler runtimes, and
  packaged DLLs;
- archive the SBOM, corresponding-source bundle digest, and notice bundle with the release record.

## Implementation phases

### Phase 0 — adopt the decision

- [x] Confirm BSL-1.0 as the project license.
- [ ] Confirm ownership of all project-authored commits.
- [x] Decide whether documentation is also BSL-1.0; this plan recommends yes. **Yes** — docs are
      covered by its own `.license` sidecar.
- [x] Record the decision in a dated commit.

**Exit criterion:** the copyright holder has explicitly approved the license and scope.

### Phase 1 — remove publication blockers

- [x] Replace or remove the 47 unprovenanced UIC files — **resolved by establishing provenance
      instead of removing them** (2026-08-14). All 60 are byte-identical to
      `tests/auto/uic/baseline/` in `github.com:qt/qt` at
      `0a2f2382541424726168804be2c90b91381608c6` (v4.8.7-3); each carries a `.license` sidecar with
      repository, revision, path, SHA-256 and the date of the check, and the terms are the ones
      those files state. `LICENSES/` gained LGPL-2.1, LGPL-3.0 and GPL-3.0 because the repository
      now asserts them.
- [x] Account for the 13 UIC files with legacy Qt headers — same measurement; the 13 are the subset
      whose headers survived, and they carry the same expression as the other 47.
- [ ] Remove vendored `tests/qmltc/cpptypes` upstream sources from distributable Git content.
      **Still open, and it is a decision for the copyright holder**: the 19 upstream files are
      GPL-3.0-only and the repository now ships that text, so the transmission is lawful; whether to
      keep vendoring them is a preference, not a blocker.
- [ ] Add a pinned, checksum-verified external-corpus test path.
- [x] Update `THIRD-PARTY.md` from investigation notes to a complete inventory — it now records the
      three populations of `cpptypes` counted file by file, and the established `.ui` provenance.

**Exit criterion:** every tracked file has known ownership and applicable terms. **MET on
2026-08-14**, and enforced rather than asserted: `license-publishable` is a mandatory gate and
reports 567 tracked files with zero unestablished terms. What remains open above is not a licensing
blocker.

### Phase 2 — establish license metadata

- [x] Add `LICENSE` and the required `LICENSES/` texts. BSL-1.0, GPL-3.0-only, LGPL-2.1-only,
      LGPL-3.0-only and the LicenseRef-Qt-Commercial record are present — every expression this
      repository asserts now travels with it. Originally this line also added `REUSE.toml`; the
      plan says to add a license text only when something actually needs it, and the GPL-3.0-only
      material is covered by an SPDX expression, not by a copy of the text it never ships with.
- [x] Add SPDX coverage to all project-authored files — IN the files. 270 further headers and 106
      `<name>.license` sidecars (61 of them NOASSERTION) replaced `REUSE.toml`, which is deleted.
      The map was not merely redundant: `override` gave The Qt Company 22 files written here,
      first-match glob resolution licensed 47 unprovenanced `.ui` files as ours, a `case` list in
      the gate covered 27 files the map never mentioned, and round 16 #8 showed a file could not
      state the licence its own annotation gave it without turning the build red. A file answers
      for itself now, and `license-coverage` refuses to run if the map comes back.
- [x] Preserve upstream headers unchanged. 102 third-party files untouched, and `license-coverage`
      fails if one of them ever acquires ours.
- [x] Add BSL-1.0 to every DUB manifest, including the one `tests/install.sh` writes.
- [x] Add DCO-based contribution instructions (`CONTRIBUTING.md`).

**Exit criterion:** `reuse lint` passes from a clean checkout. **Not met as stated:** `reuse` is not
installed here. `license-coverage` defers to it when present and otherwise runs the narrower check —
every tracked file answering for itself (own header, else its own tracked `.license` sidecar), and no third-party file carrying ours — and
says which of the two it did. 545 files covered.

### Phase 3 — license generated and installed artifacts

- [x] Add the output notice to the generator manifest — every emitted `.d` and `.cpp`.
- [x] Add machine-readable output provenance: a `// provenance:` line with generator revision, Qt
      version, module list and spec, IN the file — a file travels alone, into bug reports and into
      other people's vendor directories.
- [x] Copy license and notice files into installed packages (`LICENSE`, `LICENSES/`, `NOTICE`).
- [x] Validate the installed package. `license-package` reads the package rather than the tree:
      LICENSE, `LICENSES/BSL-1.0.txt`, NOTICE naming Qt's terms, a `license` field in `dub.json`,
      an SPDX header on every `.d` and a `// provenance:` line on every one that is not a verbatim
      copy of a `runtime/` file, no `cpptypes`/corpus/validator/object/fixture, and no absolute
      build path. Nine planted violations, nine distinct refusals — and, because those plantings
      were deleted afterwards and the proof would otherwise live only in a transcript,
      `license-package-probe` is a standing gap probe: it copies the real package, removes LICENSE,
      requires the refusal, and deletes the broken copy while carrying the exit status past the
      cleanup.
      Attacking the gate itself found six more defects in it, all fixed: it swept only `.d` while
      Phase 3 covers `.d` **and** `.cpp`; it used `grep -I`, which skips binaries by definition, so
      the three shipped archives were unexaminable (measured clean today — zero occurrences, no `/`
      in any member name, no debug sections — but nothing was enforcing it, and `-g` would bury the
      builder's home directory where the check could not look); an absent package returned 0, the
      "silently degrades" shape this repository condemns in writing; and — the worst — a cap of
      three messages written as `[ n -le 3 ] && fail …` at the end of a loop body, which under
      `set -e` KILLED the script: measured with five missing headers, it printed three and died, so
      the corpus, absolute-path and licence-file checks never ran. The verdict was still 1, which is
      why it looked fine.
      It also found the `NOTICE` cross-reference: the Qt module list printed
      `${qlibs_human:-see qtd-build.txt}`, `qlibs_human` was defined nowhere in the repository, and
      `qtd-build.txt` did not list the modules either — a dead reference in the one field that
      decides whether the reader's obligation is LGPL or GPL. Both files now carry the list.
      It found two real defects on its first runs, both invisible from the source tree:
      **(a)** the install guard listed only `gen.stamp` in its `newerThan`, so editing
      `install.sh` re-ran the command and the command then exited 0 — the package on disk was two
      days stale and had no licence in it while every tree-level gate was green;
      **(b)** `qtd-build.txt` shipped `generated-from=/home/<user>/lab/...`, the absolute path of the
      build machine, now recorded relative to the repository.
      The one bullet not covered: this validates the LDC/DMD package as **installed**, which is what
      `dub-consumer-ldc2`/`-dmd` then consume; there is no separate tarball round-trip.
- [x] Document the generated-output grant and input boundary (`docs/licensing.md`).

**Exit criterion:** a consumer can determine the license and provenance using only the installed
package.

### Phase 4 — isolate GPL-only test dependencies

- [ ] Move and mark the Qt Qml Compiler validator as a GPL test island.
- [ ] Remove it from default product/release aggregates.
- [x] Add dependency and binary-import deny gates (`license-no-gpl-product`): product specs and the
      undefined symbols of every archive. Proven to bite by adding Qt6Mqtt to a spec.
- [ ] Ensure GPL test CI jobs retain no downloadable executable artifacts.

**Exit criterion:** product package inspection finds no GPL-only linked component.

### Phase 5 — create the Qt module license gate

- [ ] Maintain versioned allow/deny data derived from official Qt material.
- [ ] Inventory every private header.
- [ ] Consume Qt SPDX SBOMs where available.
- [ ] Fail closed when module or header licensing is unknown.
- [ ] Add the WebEngine-specific profile.

**Exit criterion:** changing a spec to add a GPL-only module makes the release build fail with a
specific licensing diagnostic.

### Phase 6 — prepare Windows distribution

- [ ] Build Qt dynamically and prove no static Qt object is linked.
- [ ] Stage the actual DLL/plugin set.
- [ ] Produce notices and corresponding-source bundle for the exact Qt build.
- [ ] Write DLL replacement and rebuild instructions.
- [ ] Test replacement with a compatible locally rebuilt Qt DLL.
- [ ] Review EULA and delivery-channel restrictions.
- [ ] Generate and archive the release SBOM.

**Exit criterion:** the Windows bundle passes `license-windows-bundle` on a clean machine and its
source/notice bundle is retrievable independently of qt.io.

### Phase 7 — first publication review

- [ ] Give counsel the source tree, final package, Windows bundle, SBOM, module map, private-header
  inventory, source bundle, notices, and distribution terms.
- [ ] Resolve findings in code or packaging rather than only in prose.
- [ ] Tag the reviewed licensing policy version in release metadata.

**Exit criterion:** the reviewed artifacts are byte-for-byte the artifacts published.

## Release checklist

A release manager must be able to answer **yes** to all of these:

- [ ] Does every tracked or packaged file have an identified license and owner?
- [ ] Are all project-owned components declared BSL-1.0?
- [ ] Are generated sources marked and accompanied by the output policy?
- [ ] Are the GPL Qt corpus and GPL validator absent from product artifacts?
- [ ] Are all linked Qt modules allowed for this exact Qt version?
- [ ] Were private Qt headers checked at the file level?
- [ ] Is Qt dynamically linked in the LGPL distribution profile?
- [ ] Can an end user replace the shipped Qt shared libraries and still run the application?
- [ ] Are license notices prominent and complete?
- [ ] Is exact corresponding source under the distributor's control?
- [ ] Does the application EULA preserve LGPL reverse-engineering and modification rights?
- [ ] If WebEngine is present, was its separate profile completed?
- [ ] Does the unpacked package pass every licensing gate?
- [ ] Does the archived SBOM describe the bytes actually released?

Any “no” blocks release. Commercial Qt is an alternative distribution model, not a mechanism for
waiving unresolved provenance in this repository or third-party obligations such as Chromium's.

## Definition of done

This plan is complete when:

1. the repository and every DUB package state BSL-1.0 accurately;
2. all project-authored and third-party files have machine-checkable license coverage;
3. unprovenanced and vendored GPL test corpora are absent from public artifacts;
4. the Qt Qml Compiler dependency is test-only, marked, and mechanically excluded from releases;
5. generated bindings carry an explicit output grant and provenance;
6. product builds fail automatically on GPL-only or unknown Qt dependencies;
7. a Windows LGPL bundle provides notices, corresponding source, replacement instructions, and a
   verifiable SBOM for the exact shipped Qt build;
8. the first actual release—not merely this plan—has received the intended legal review.
