#!/usr/bin/env python3
"""Untimed bound-global discovery, isolation and type-retention audit (#515)."""

from audit_globals import Case, audit


def cases() -> list[Case]:
    result = []
    visible = {
        "simple": "var sharedValue = 1;\n",
        "comma": "var first = 0, sharedValue = 1;\n",
        "destructured": "var { sharedValue } = { sharedValue: 1 };\n",
        "block": "if (true) { var sharedValue = 1; }\n",
        "comment": "/*\nexport {}\n*/\nvar sharedValue = 1;\n",
        "escaped": "var sh\\u0061redValue = 1;\n",
    }
    isolated = {
        "inline-module": "var privateValue = 1; export {};\n",
        "function": "function scope() { var privateValue = 1; }\n",
        "namespace": "namespace Scope { export var privateValue = 1; }\n",
        "lexical-block": "{ let privateValue = 1; }\n",
        "lexical-loop": "for (let privateValue = 0; privateValue < 1; privateValue++) {}\n",
    }
    for order, filename in (("before", "a-definitions.ts"), ("after", "z-definitions.ts")):
        for shape, declaration in visible.items():
            good = "const good: number = globalThis.sharedValue;\n"
            for control, extra, expected in (
                ("positive", "", ()),
                ("missing", "globalThis.missingValue;\n", ("7017",)),
                ("wrong-type", "const bad: string = globalThis.sharedValue;\n", ("2322",)),
            ):
                result.append(Case(f"{shape}/{order}/{control}", "visible",
                                   {filename: declaration, "app.ts": good + extra}, expected))
        for shape, declaration in isolated.items():
            good = "const good: number = 1;\n"
            for control, extra, expected in (
                ("positive", "", ()),
                ("negative", "globalThis.privateValue;\n", ("7017",)),
            ):
                result.append(Case(f"{shape}/{order}/{control}", "isolated",
                                   {filename: declaration, "app.ts": good + extra}, expected))
    return result


if __name__ == "__main__":
    raise SystemExit(audit(cases()))
