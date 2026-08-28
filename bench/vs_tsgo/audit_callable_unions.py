#!/usr/bin/env python3
"""Untimed callable-union controls for #511; every case is mandatory."""

from __future__ import annotations

import argparse

from audit_globals import Case, audit


FAMILIES = ("plain", "different-target", "same-target", "receiver")
SHAPES = ("array", "array-object", "conditional", "conditional-object")


def cases(family: str | None = None) -> list[Case]:
    result = []
    for group in FAMILIES:
        if family is not None and family != group:
            continue
        if group == "receiver":
            declarations = (
                "declare function left(this: { left: number }): number;",
                "declare function right(this: { right: number }): number;",
            )
        else:
            right_return = {"plain": "boolean", "different-target": "value is string",
                            "same-target": "value is number"}[group]
            declarations = (
                "declare function left(value: unknown): value is number;",
                f"declare function right(value: unknown): {right_return};",
            )
        for declaration_order, ordered in (("forward", declarations), ("reverse", declarations[::-1])):
            for branch_order, branches in (("forward", ("left", "right")), ("reverse", ("right", "left"))):
                for shape in SHAPES:
                    expressions = [f"{{ run: {branch} }}" if shape.endswith("object") else branch
                                   for branch in branches]
                    array = shape.startswith("array")
                    expression = f"[{', '.join(expressions)}]" if array else f"flag ? {expressions[0]} : {expressions[1]}"
                    selected = "selected[0]" if array else "selected"
                    callee = f"{selected}.run" if shape.endswith("object") else selected
                    if group == "receiver":
                        valid = f"const complete = {{ left: 1, right: 2, run: {callee} }};\nconst good: number = complete.run();\n"
                        invalid = f"const partial = {{ left: 1, run: {callee} }};\npartial.run();\n"
                        code = "2684"
                    else:
                        good_type = {"plain": "unknown", "different-target": "string | number",
                                     "same-target": "number"}[group]
                        bad_type = "string" if group == "same-target" else "number"
                        valid = f"if ({callee}(value)) {{ const good: {good_type} = value; }}\n"
                        invalid = f"if ({callee}(value)) {{ const bad: {bad_type} = value; }}\n"
                        code = "2322"
                    for scope, prefix in (("script", ""), ("module", "export {};\n")):
                        source = (prefix + "declare const flag: boolean;\ndeclare let value: unknown;\n"
                                  + "\n".join(ordered) + f"\nconst selected = {expression};\n" + valid)
                        name = f"decl-{declaration_order}/branch-{branch_order}/{shape}/{scope}"
                        result.append(Case(f"{name}/positive", group, {"app.ts": source}, ()))
                        result.append(Case(f"{name}/negative", group, {"app.ts": source + invalid}, (code,)))
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--family", choices=FAMILIES)
    return audit(cases(parser.parse_args().family))


if __name__ == "__main__":
    raise SystemExit(main())
