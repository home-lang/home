#!/usr/bin/env python3
"""Untimed imported-owner isolation checks for #487; no known failures waived."""

from __future__ import annotations

import argparse

from audit_globals import Case, audit


IMPORTS = "import * as first from './a-first';\nimport * as second from './b-second';\n"


def cases(family: str | None = None) -> list[Case]:
    result = []

    def pair(name, first, second, valid, invalid, expected):
        for order, app in (("before", "0-app.ts"), ("after", "z-app.ts")):
            for control, statements, codes in (("positive", valid, ()), ("negative", valid + invalid, expected)):
                result.append(Case(
                    f"app-{order}/{control}", name,
                    {"a-first.ts": first, "b-second.ts": second, app: IMPORTS + statements}, codes,
                ))

    pair(
        "generic",
        "export interface Box<T> { value: T; }\nexport declare function identity<T extends string>(value: T): Box<T>;\n",
        "export interface Box<T> { value: T; }\nexport declare function identity<T extends number>(value: T): Box<T>;\n",
        "const text: string = first.identity('ok').value;\nconst count: number = second.identity(42).value;\n",
        "const badText: number = first.identity('ok').value;\nconst badCount: string = second.identity(42).value;\n"
        "first.identity(42);\nsecond.identity('bad');\n",
        ("2322", "2322", "2345", "2345"),
    )
    # Repeat the valid branch in the negative project so both variants use the
    # same unknown values and guards. Only deliberately invalid uses differ.
    pair(
        "predicate",
        "export declare function guard(value: unknown): value is string;\n",
        "export declare function guard(value: unknown): value is number;\n",
        "declare let text: unknown;\ndeclare let count: unknown;\n"
        "if (first.guard(text)) { const good: string = text; }\n"
        "if (second.guard(count)) { const good: number = count; }\n",
        "if (first.guard(text)) { const bad: number = text; text.missing; }\n"
        "if (second.guard(count)) { const bad: string = count; count.missing; }\n",
        ("2322", "2339", "2322", "2339"),
    )
    pair(
        "private-origin",
        "export declare class Secret { private key: string; read(): string; }\n",
        "export declare class Secret { private key: string; read(): string; }\n",
        "declare const left: first.Secret;\ndeclare const right: second.Secret;\n"
        "const leftCopy: first.Secret = left;\nconst rightCopy: second.Secret = right;\n",
        "const badLeft: first.Secret = right;\nconst badRight: second.Secret = left;\n",
        ("2322", "2322"),
    )
    pair(
        "rest",
        "export declare function tuple(...args: [number, string]): number;\n",
        "export declare function tuple(...args: [string, number]): number;\n",
        "const left: number = first.tuple(1, 'ok');\nconst right: number = second.tuple('ok', 1);\n",
        "first.tuple('bad', 1);\nsecond.tuple(1, 'bad');\n",
        ("2345", "2345"),
    )
    pair(
        "readonly",
        "export interface Box { readonly value: string; }\n",
        "export interface Box { value: number; }\n",
        "declare const left: first.Box;\ndeclare const right: second.Box;\n"
        "const text: string = left.value;\nconst count: number = right.value;\nright.value = 42;\n",
        "left.value = 'changed';\nright.value = 'bad';\n",
        ("2540", "2322"),
    )
    return [case for case in result if family is None or case.family == family]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--family", choices=("generic", "predicate", "private-origin", "rest", "readonly"))
    args = parser.parse_args()
    return audit(cases(args.family))


if __name__ == "__main__":
    raise SystemExit(main())
