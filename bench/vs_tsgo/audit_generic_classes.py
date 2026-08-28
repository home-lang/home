#!/usr/bin/env python3
"""Untimed source-owned imported generic-class controls for #524."""

from audit_globals import Case, audit


BOX = "export declare class Box<T> { private key: string; value: T; }\n"


def cases() -> list[Case]:
    result = []

    def pair(family, sources, valid, invalid, expected=("2322",)):
        for order, app in (("before", "0-app.ts"), ("after", "z-app.ts")):
            for control, statements, codes in (("positive", valid, ()), ("negative", valid + invalid, expected)):
                result.append(Case(f"app-{order}/{control}", family, {**sources, app: statements}, codes))

    for family, imports, name, extra in (
        ("named", "import { Box } from './a-owner';\n", "Box", {}),
        ("namespace", "import * as ns from './a-owner';\n", "ns.Box", {}),
        ("renamed", "import { Box as Renamed } from './a-owner';\n", "Renamed", {}),
        ("default", "import Local from './b-barrel';\n", "Local", {"b-barrel.ts": "export { Box as default } from './a-owner';\n"}),
        ("reexport", "import { Alias } from './b-barrel';\n", "Alias", {"b-barrel.ts": "export { Box as Alias } from './a-owner';\n"}),
    ):
        pair(family, {"a-owner.ts": BOX, **extra}, imports + f"declare const value: {name}<string>;\n"
             f"const good: {name}<string> = value;\nconst text: string = value.value;\n",
             f"const bad: {name}<number> = value;\n")

    imports = "import * as ns from './a-owner';\n"
    for family, member in (
        ("array-member", "T[]"), ("readonly-array-member", "readonly T[]"),
        ("object-member", "{ inner: T }"), ("tuple-member", "[T, T?]"),
        ("union-member", "T | undefined"), ("function-member", "(value: T) => T"),
    ):
        pair(family, {"a-owner.ts": BOX.replace("value: T", f"value: {member}")},
             imports + "declare const value: ns.Box<string>;\nconst good: ns.Box<string> = value;\n",
             "const bad: ns.Box<number> = value;\n")
    pair("method-member", {"a-owner.ts": BOX.replace("value: T;", "identity(value: T): T;")},
         imports + "declare const value: ns.Box<string>;\nconst good: string = value.identity('ok');\n",
         "const bad: number = value.identity('ok');\nvalue.identity(1);\n", ("2322", "2345"))
    pair("owner-identity", {"a-owner.ts": BOX, "b-other.ts": BOX.replace("<T>", "<U>").replace("value: T", "value: U")},
         imports + "import * as other from './b-other';\ndeclare const value: ns.Box<string>;\n"
         "const good: ns.Box<string> = value;\n",
         "const bad: other.Box<string> = value;\n")
    pair("local-name-isolation", {"a-owner.ts": BOX},
         imports + "type T = number;\nclass Box { local!: number; }\n"
         "declare const value: ns.Box<string>;\nconst good: string = value.value;\n"
         "const local: Box = { local: 1 };\n", "const bad: number = value.value;\n")
    pair("default-argument", {"a-owner.ts": BOX.replace("<T>", "<T = string>")},
         imports + "declare const value: ns.Box;\nconst good: ns.Box<string> = value;\n"
         "const text: string = value.value;\n", "const bad: ns.Box<number> = value;\n")
    pair("dependent-default", {"a-owner.ts": "export declare class Box<T = string, U = T[]> { value: U; }\n"},
         imports + "declare const value: ns.Box<number>;\nconst good: number[] = value.value;\n",
         "const bad: string[] = value.value;\n")
    pair("constraint", {"a-owner.ts": BOX.replace("<T>", "<T extends { id: string }>")},
         imports + "declare const good: ns.Box<{ id: string; extra: number }>;\n",
         "declare const bad: ns.Box<{ id: number }>;\n", ("2344",))
    pair("dependent-constraint", {"a-owner.ts": "export declare class Box<T, U extends T> { value: U; }\n"},
         imports + "declare const good: ns.Box<string, 'ok'>;\n",
         "declare const bad: ns.Box<string, number>;\n", ("2344",))
    pair("required-arity", {"a-owner.ts": BOX}, imports + "declare const good: ns.Box<string>;\n",
         "declare const bad: ns.Box;\n", ("2314",))
    pair("excess-arity", {"a-owner.ts": BOX}, imports + "declare const good: ns.Box<string>;\n",
         "declare const bad: ns.Box<string, number>;\n", ("2314",))
    pair("default-arity", {"a-owner.ts": BOX.replace("<T>", "<T = string>")},
         imports + "declare const good: ns.Box;\n", "declare const bad: ns.Box<string, number>;\n", ("2707",))
    pair("owner-local-alias", {"a-owner.ts": "type Wrap<X> = { item: X };\n" + BOX.replace("value: T", "value: Wrap<T>")},
         imports + "type Wrap<X> = { local: number };\ndeclare const value: ns.Box<string>;\n"
         "const good: string = value.value.item;\n", "const bad: number = value.value.item;\n")
    pair("owner-imported-alias", {"a-owner.ts": "import { Wrap } from './b-helper';\n" + BOX.replace("value: T", "value: Wrap<T>"),
                                  "b-helper.ts": "export type Wrap<X> = { item: X };\n"},
         imports + "declare const value: ns.Box<string>;\nconst good: string = value.value.item;\n",
         "const bad: number = value.value.item;\n")
    pair("owner-local-constraint", {"a-owner.ts": "type Item = { id: string };\n" + BOX.replace("<T>", "<T extends Item = Item>")},
         imports + "type Item = { id: number };\ndeclare const value: ns.Box;\n"
         "const good: string = value.value.id;\n", "declare const bad: ns.Box<Item>;\n", ("2344",))
    pair("recursive-alias", {"a-owner.ts": "type Link<X> = { item: X; next?: Link<X> };\n" + BOX.replace("value: T", "value: Link<T>")},
         imports + "declare const value: ns.Box<string>;\nconst good: string = value.value.item;\n"
         "const next: string | undefined = value.value.next?.item;\n",
         "const bad: number = value.value.item;\n")
    pair("growing-recursive-alias", {"a-owner.ts": "type Link<X> = { item: X; next?: Link<X[]> };\n" + BOX.replace("value: T", "value: Link<T>")},
         imports + "declare const value: ns.Box<string>;\nconst good: string = value.value.item;\n"
         "const next: string[] | undefined = value.value.next?.item;\n",
         "const bad: number[] | undefined = value.value.next?.item;\n")
    phantom = "export declare class Box<T> { private key: string; }\n"
    pair("phantom-parameter", {"a-owner.ts": phantom, "b-other.ts": phantom},
         imports + "import * as other from './b-other';\ndeclare const value: ns.Box<string>;\n"
         "const compatible: ns.Box<number> = value;\n",
         "const bad: other.Box<string> = value;\n")
    pair("explicit-this-method", {"a-owner.ts": BOX.replace("value: T;", "value: T; identity(this: { value: T }, value: T): T;")},
         imports + "declare const value: ns.Box<string>;\nconst good: string = value.identity('ok');\n"
         "const detached = value.identity;\n", "detached('ok');\n", ("2684",))
    return result


if __name__ == "__main__":
    raise SystemExit(audit(cases()))
