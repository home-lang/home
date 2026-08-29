#!/usr/bin/env python3
"""Untimed controls for real declaration identity through module projections."""

from audit_globals import Case, audit


def cases() -> list[Case]:
    graphs = {
        "distinct": (
            {"left.ts": "export const shared = 1;\n", "right.ts": "export const shared = 2;\n"},
            "export * from './left';\n", "export * from './right';\n", ("2308",),
        ),
        "same-origin": (
            {"leaf.ts": "export const shared = 1;\n", "left.ts": "export * from './leaf';\n",
             "right.ts": "export * from './leaf';\n", "other.ts": "export const shared = 2;\n"},
            "export * from './left'; export * from './right';\n", "export * from './other';\n", ("2308",),
        ),
        "default-alias": (
            {"leaf.ts": "export default class Shared {} export { Shared };\n",
             "left.ts": "export { Shared } from './leaf';\n",
             "right.ts": "import Shared from './leaf'; export { Shared };\n",
             "other.ts": "export class Shared {}\n"},
            "export * from './left'; export * from './right';\n", "export * from './other';\n", ("2308",),
        ),
        "missing-alias": (
            {"leaf.ts": "export const original = 1;\n",
             "alias.ts": "import { original as local } from './leaf'; export { local as exposed };\n"},
            "import { exposed } from './alias'; export { exposed };\n",
            "import { missing } from './alias';\n", ("2305",),
        ),
        "type-only-alias": (
            {"leaf.ts": "export function fn(value: number): number { return value; }\n",
             "alias.ts": "import type { fn } from './leaf'; export { fn };\n"},
            "import type { fn } from './alias';\n",
            "import type { missing } from './alias';\n", ("2305",),
        ),
        "type-only-runtime": (
            {"leaf.ts": "export function fn(value: number): number { return value; }\n",
             "alias.ts": "import type { fn } from './leaf'; export { fn };\n"},
            "import { fn } from './alias';\n"
            "function local(fn: (value: number) => number) { return fn(1); }\n",
            "fn(1);\n", ("1361",),
        ),
    }
    for projection, source in (("named", "export { fn } from './alias';\n"),
                               ("star", "export * from './alias';\n")):
        graphs[f"type-only-runtime-{projection}"] = (
            {"leaf.ts": "export function fn(value: number): number { return value; }\n",
             "alias.ts": "import type { fn } from './leaf'; export { fn };\n",
             "barrel.ts": source},
            "import { fn } from './barrel';\n"
            "function local(fn: (value: number) => number) { return fn(1); }\n",
            "fn(1);\n", ("1361",),
        )
    result = []
    for family, (files, valid, invalid, expected) in graphs.items():
        for root_mode, roots in (("entry-only", ("entry.ts",)), ("all-files", None)):
            result.append(Case(f"{root_mode}/positive", family, {**files, "entry.ts": valid}, (), roots))
            result.append(Case(f"{root_mode}/negative", family, {**files, "entry.ts": valid + invalid}, expected, roots))
    return result


if __name__ == "__main__":
    raise SystemExit(audit(cases()))
