# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# Sphinx configuration for the DSide / xiboca manual.
#
# reStructuredText and the stock theme, deliberately: this machine has Sphinx but
# neither myst-parser nor a third-party theme, and `docs-sphinx` has to build with
# what is installed or it is not a gate. Markdown sources would mean adding a
# dependency to the build before there is a page to justify it.

project = "DSide"
author = "Marcelo A Caetano"
copyright = "2026, Marcelo A Caetano"

extensions = []
templates_path = []
exclude_patterns = ["_build"]

# -W is passed on the command line by tests/docs-sphinx.sh, so anything Sphinx can
# detect — a broken cross-reference, a page missing from every toctree, a malformed
# table — fails the build rather than producing a page that looks fine and lies.
nitpicky = True

html_theme = "alabaster"
html_static_path = []
html_title = "DSide — Qt for D"
# The logo lives in branding/, outside this tree, and docs-sphinx assembles the source
# into a temporary directory when it has a generated API reference to add — where a
# relative path out of the tree no longer resolves. Resolve it, and simply go without
# when it is not there, rather than emitting a warning that -W turns into a failure
# over a decoration.
import os
_logo = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                     "..", "..", "branding", "xiboca-icon-256.png")
html_logo = _logo if os.path.exists(_logo) else None
html_show_sourcelink = True

# The manual describes two products with two audiences; see docs/documentation-plan.md.
html_short_title = "DSide"
