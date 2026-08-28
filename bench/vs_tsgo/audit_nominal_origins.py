#!/usr/bin/env python3
"""Untimed imported-class declaration-identity controls for #521 and #487."""

from __future__ import annotations

import argparse

from audit_globals import Case, audit


IMPORTS = "import * as first from './a-first';\nimport * as second from './b-second';\n"
PRIVATE = "export declare class Secret { private key: string; value: string; }\n"
VALUES = "declare const left: first.Secret;\ndeclare const right: second.Secret;\n"


def cases(family: str | None = None) -> list[Case]:
    result = []

    def pair(name, first, second, valid, invalid, expected=("2322",), *, siblings=None):
        for order, app in (("before", "0-app.ts"), ("after", "z-app.ts")):
            for control, statements, codes in (("positive", valid, ()), ("negative", valid + invalid, expected)):
                result.append(Case(
                    f"app-{order}/{control}", name,
                    {"a-first.ts": first, "b-second.ts": second, **(siblings or {}), app: IMPORTS + statements},
                    codes,
                ))

    pair("private-direct", PRIVATE, PRIVATE, VALUES + "const copy: first.Secret = left;\n",
         "const bad: first.Secret = right;\n")
    static = PRIVATE.replace("private key", "private static key")
    pair("private-static", static, static,
         "declare const left: typeof first.Secret;\ndeclare const right: typeof second.Secret;\n"
         "const copy: typeof first.Secret = left;\n",
         "const bad: typeof first.Secret = right;\n")
    pair("private-nested", PRIVATE, PRIVATE,
         VALUES + "const good: { inner: { item: first.Secret } } = { inner: { item: left } };\n",
         "const bad: { inner: { item: first.Secret } } = { inner: { item: right } };\n")
    pair("private-array", PRIVATE, PRIVATE, VALUES + "const good: first.Secret[] = [left];\n",
         "const bad: first.Secret[] = [right];\n")
    pair("private-function", PRIVATE, PRIVATE,
         VALUES + "declare const make: () => first.Secret;\ndeclare const use: (value: first.Secret) => void;\n"
         "const goodMake: () => first.Secret = make;\nconst goodUse: (value: first.Secret) => void = use;\n",
         "const badMake: () => second.Secret = make;\nconst badUse: (value: second.Secret) => void = use;\n",
         ("2322", "2322"))
    pair("private-generic", PRIVATE.replace("Secret {", "Secret<T> {").replace("value: string", "value: T"),
         PRIVATE.replace("Secret {", "Secret<T> {").replace("value: string", "value: T"),
         "declare const left: first.Secret<string>;\ndeclare const right: second.Secret<string>;\n"
         "const good: first.Secret<string> = left;\n",
         "const badOwner: first.Secret<string> = right;\nconst badArgument: first.Secret<number> = left;\n",
         ("2322", "2322"))
    pair("private-alias", PRIVATE, PRIVATE,
         VALUES + "import { Secret as Alias } from './c-alias';\ndeclare const alias: Alias;\n"
         "const fromAlias: first.Secret = alias;\nconst toAlias: Alias = left;\n",
         "const bad: Alias = right;\n", siblings={"c-alias.ts": "export { Secret } from './a-first';\n"})
    pair("private-public-surface", PRIVATE, "export {};\n",
         "declare const left: first.Secret;\nconst good: { value: string } = left;\n"
         "declare const structural: { key: string; value: string };\n",
         "const bad: first.Secret = structural;\n")
    public = PRIVATE.replace("private key", "key")
    pair("public-structural", public, public,
         VALUES + "const leftCopy: first.Secret = right;\nconst rightCopy: second.Secret = left;\n",
         "const bad: { value: number } = left;\n")
    pair("private-keyof", PRIVATE, PRIVATE, "const good: keyof first.Secret = 'value';\n",
         "const bad: keyof first.Secret = 'key';\n")
    protected = PRIVATE.replace("private key", "protected key")
    pair("protected-direct", protected, protected, VALUES + "const good: first.Secret = left;\n",
         "const bad: first.Secret = right;\n")
    # Inheritance is intentionally retained even while Program's legacy class
    # projection is incomplete. Do not count a reduced nominal subset as full
    # imported-class parity or silently skip these positive controls.
    for visibility in ("private", "protected"):
        base = PRIVATE.replace("private key", f"{visibility} key")
        pair(f"{visibility}-inherited", base + "export declare class Child extends Secret {}\n",
             base + "export declare class Child extends Secret {}\n",
             "declare const base: first.Secret;\ndeclare const child: first.Child;\n"
             "declare const other: second.Child;\nconst good: first.Secret = child;\n"
             "const sameFamily: first.Child = base;\n",
             "const bad: first.Secret = other;\n")

    return [case for case in result if family is None or case.family == family]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--family", choices=sorted({case.family for case in cases()}))
    args = parser.parse_args()
    return audit(cases(args.family))


if __name__ == "__main__":
    raise SystemExit(main())
