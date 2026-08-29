#!/usr/bin/env python3
"""Untimed import/re-export discovery controls, distinct from typed linkage."""

from audit_globals import Case, audit


def cases() -> list[Case]:
    leaf = "export interface Shape { value: number; }\nexport const answer: number = 1;\n"
    invalid = "export const invalid: string = answer;\n"
    graphs = {
        "import": {
            "entry.ts": "import { answer } from './middle'; export { answer };\n",
            "middle.ts": "import { answer } from './leaf'; export { answer };\n",
        },
        "named": {
            "entry.ts": "export { answer } from './middle';\n",
            "middle.ts": "export { answer } from './leaf';\n",
        },
        "star": {
            "entry.ts": "export * from './middle';\n",
            "middle.ts": "export * from './leaf';\n",
        },
        "namespace": {
            "entry.ts": "export * as group from './middle';\n",
            "middle.ts": "export * as group from './leaf';\n",
        },
        "type-only": {
            "entry.ts": "export type { Shape } from './middle';\n",
            "middle.ts": "export type { Shape } from './leaf';\n",
        },
        "cycle": {
            "entry.ts": "export * from './middle';\n",
            "middle.ts": "export * from './entry'; export * from './leaf';\n",
        },
        "diamond": {
            "entry.ts": "export * from './left'; export * from './right';\n",
            "left.ts": "export * from './leaf';\n",
            "right.ts": "export * from './leaf';\n",
        },
    }
    result = []
    for family, graph in graphs.items():
        for root_mode, roots in (("entry-only", ("entry.ts",)), ("all-files", None)):
            for control, suffix, expected in (("positive", "", ()), ("negative", invalid, ("2322",))):
                result.append(Case(
                    f"{root_mode}/{control}", family,
                    {**graph, "leaf.ts": leaf + suffix}, expected, roots,
                ))
    return result


if __name__ == "__main__":
    raise SystemExit(audit(cases()))
