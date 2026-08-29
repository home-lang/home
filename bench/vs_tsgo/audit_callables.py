#!/usr/bin/env python3
"""Untimed callable-identity controls for #507; no failures are waived."""

from __future__ import annotations

import argparse

from audit_globals import Case, audit


FAMILIES = ("alias", "direct", "wrapper", "assignment", "rest", "optional", "generic")


def cases(family: str | None = None) -> list[Case]:
    result = []
    predicate_members = (
        "number(value: unknown): value is number;",
        "plain(value: unknown): boolean;",
    )
    definitions = {
        "alias": (predicate_members,
                  "const goodGuard = operations.number; if (goodGuard(value)) { const good: number = value; }",
                  "const plain = operations.plain; if (plain(value)) { const bad: number = value; }", "2322"),
        "direct": (predicate_members,
                   "if (operations.number(value)) { const good: number = value; }",
                   "if (operations.plain(value)) { const bad: number = value; }", "2322"),
        "wrapper": (predicate_members,
                    "const goodBox = { p: operations.number }; if (goodBox.p(value)) { const good: number = value; }",
                    "const badBox = { p: operations.plain }; if (badBox.p(value)) { const bad: number = value; }", "2322"),
        "assignment": (predicate_members,
                       "const goodGuard: (value: unknown) => value is number = operations.number;",
                       "const badGuard: (value: unknown) => value is number = operations.plain;", "2322"),
        "rest": (("normal(values: Values): void;", "rest(...values: Values): void;"),
                 "operations.normal(['ok']); operations.rest('ok', 'more');",
                 "operations.normal('bad');", "2345"),
        "optional": (("required(value: number | undefined): void;", "optional(value?: number): void;"),
                     "operations.required(1); operations.optional();",
                     "operations.required();", "2554"),
        "generic": (("generic<T extends string>(): void;", "ordinary(): void;"),
                    "operations.generic<'ok'>(); operations.ordinary();",
                    "operations.ordinary<string>();", "2558"),
    }
    for group, (members, valid, invalid, code) in definitions.items():
        if family is not None and family != group:
            continue
        for order, ordered in (("forward", members), ("reverse", tuple(reversed(members)))):
            for scope, prefix in (("script", ""), ("module", "export {};\n")):
                declarations = (prefix + "type Values = string[];\ninterface Operations {\n"
                                + "\n".join(ordered) + "\n}\ndeclare const operations: Operations;\n"
                                + "declare let value: unknown;\n")
                for control, statements, codes in (("positive", valid, ()),
                                                   ("negative", valid + "\n" + invalid, (code,))):
                    result.append(Case(f"{order}/{scope}/{control}", group,
                                       {"app.ts": declarations + statements + "\n"}, codes))
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--family", choices=FAMILIES, help="default: audit every family")
    return audit(cases(parser.parse_args().family))


if __name__ == "__main__":
    raise SystemExit(main())
