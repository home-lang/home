#!/usr/bin/env python3
"""Untimed static-require program-closure controls for #545 / #541."""

from audit_globals import Case, audit


VALID_LEAF = "module.exports = { value: 1 };\n"
INVALID_LEAF = "/** @type {string} */ const invalid = 1;\n"
REQUIRE_DECL = "/** @type {(path: string, ...rest: any[]) => any} */ const require = function(path, ...rest) {};\n"


def cases() -> list[Case]:
    followed = {
        "binding": {"entry.js": "const value = require('./leaf');\n"},
        "bare-nested": {"entry.js": "function load() { require('./leaf'); }\n"},
        "template": {"entry.js": "require(`./leaf`);\n"},
        "transitive": {"entry.js": "require('./middle');\n", "middle.js": "module.exports = require('./leaf');\n"},
        "cycle": {"entry.js": "require('./left');\n", "left.js": "require('./right'); require('./leaf');\n",
                  "right.js": "require('./left');\n"},
        "diamond": {"entry.js": "require('./left'); require('./right');\n",
                    "left.js": "require('./leaf');\n", "right.js": "require('./leaf');\n"},
    }
    ignored = {
        "comment": "// require('./leaf');\n",
        "string": "const text = \"require('./leaf')\";\n",
        "dynamic": "const name = './leaf'; require(name);\n",
        "property": "const loader = { require }; loader.require('./leaf');\n",
        "multiple-arguments": "require('./leaf', 1);\n",
    }
    result = []
    for family, graph in followed.items():
        for root_mode, roots in (("entry-only", ("entry.js",)), ("all-files", None)):
            for control, suffix, expected in (("positive", "", ()), ("negative", INVALID_LEAF, ("2322",))):
                result.append(Case(f"{root_mode}/{control}", family,
                                   {**graph, "entry.js": REQUIRE_DECL + graph["entry.js"],
                                    "leaf.js": VALID_LEAF + suffix}, expected, roots, check_js=True))
    for family, entry in ignored.items():
        for root_mode, roots in (("entry-only", ("entry.js",)), ("all-files", None)):
            for control, suffix in (("positive", ""), ("negative", INVALID_LEAF)):
                # Entry-only decoys must not pull in the invalid leaf; all-file
                # mode proves the same leaf diagnostic is otherwise observable.
                expected = ("2322",) if root_mode == "all-files" and control == "negative" else ()
                result.append(Case(f"{root_mode}/{control}", family,
                                   {"entry.js": REQUIRE_DECL + entry, "leaf.js": VALID_LEAF + suffix}, expected, roots, check_js=True))
    return result


if __name__ == "__main__":
    raise SystemExit(audit(cases()))
