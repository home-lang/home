#!/usr/bin/env python3
"""Untimed imported class value/namespace controls for #523; no skipped failures."""

from audit_globals import Case, audit


CLASS = "export declare class Secret { private static key: string; static count: number; value: string; }\n"


def cases() -> list[Case]:
    result = []

    def pair(family, sources, valid, invalid, expected=("2322",)):
        for order, app in (("before", "0-app.ts"), ("after", "z-app.ts")):
            for control, statements, codes in (("positive", valid, ()), ("negative", valid + invalid, expected)):
                result.append(Case(f"app-{order}/{control}", family, {**sources, app: statements}, codes))

    for family, imports, expression, extra in (
        ("named", "import { Secret } from './a-owner';\n", "Secret", {}),
        ("named-alias", "import { Alias as Local } from './b-barrel';\n", "Local",
         {"b-barrel.ts": "export { Secret as Alias } from './a-owner';\n"}),
        ("default", "import Local from './b-barrel';\n", "Local",
         {"b-barrel.ts": "export { Secret as default } from './a-owner';\n"}),
        ("namespace", "import * as ns from './a-owner';\n", "ns.Secret", {}),
        ("captured-namespace", "import * as ns from './a-owner';\nconst copy = ns;\n", "copy.Secret", {}),
        ("destructured-namespace", "import * as ns from './a-owner';\nconst { Secret } = ns;\n", "Secret", {}),
        ("element-namespace", "import * as ns from './a-owner';\n", "ns['Secret']", {}),
        ("namespace-default", "import * as ns from './b-barrel';\n", "ns.default",
         {"b-barrel.ts": "export { Secret as default } from './a-owner';\n"}),
        ("namespace-reexport", "import { bundle } from './b-barrel';\n", "bundle.Secret",
         {"b-barrel.ts": "export * as bundle from './a-owner';\n"}),
    ):
        pair(family, {"a-owner.ts": CLASS, **extra}, imports + f"const good: number = {expression}.count;\n",
             f"const bad: string = {expression}.count;\n")

    pair("mixed-exports", {"a-owner.d.ts": CLASS + "export declare const label: string;\n"
                           "export declare function identity(value: string): string;\n"},
         "import * as ns from './a-owner';\nconst copy = ns;\n"
         "const good: number = copy.Secret.count;\nconst label: string = copy.label;\n"
         "const value: string = copy.identity('ok');\n",
         "const bad: number = copy.label;\ncopy.identity(1);\n", ("2322", "2345"))
    pair("namespace-name-isolation", {"a-owner.ts": CLASS},
         "import * as ns from './a-owner';\nclass Secret { local!: number; }\n"
         "const count: number = ns.Secret.count;\nconst local: Secret = { local: 1 };\n",
         "const bad: Secret = { local: 'bad' };\n")
    for family, imports, name, shape, expression in (
        ("named-shadow", "import { Secret } from './a-owner';\n", "Secret", "{ count: string }", "Secret.count"),
        ("namespace-shadow", "import * as ns from './a-owner';\n", "ns", "{ Secret: { count: string } }", "ns.Secret.count"),
    ):
        pair(family, {"a-owner.ts": CLASS}, imports + f"function good({name}: {shape}): string {{ return {expression}; }}\n",
             f"function bad({name}: {shape}): number {{ return {expression}; }}\n")
    pair("private-static-identity", {"a-owner.ts": CLASS, "b-other.ts": CLASS},
         "import * as first from './a-owner';\nimport * as second from './b-other';\n"
         "const good: typeof first.Secret = first.Secret;\n",
         "const bad: typeof first.Secret = second.Secret;\n")
    pair("namespace-visibility", {"a-owner.ts": "export class Visible {}\n"
                                  "export namespace Visible { const hidden = 1; export const shown = 1; }\n"},
         "import { Visible } from './a-owner';\nconst good: number = Visible.shown;\n",
         "Visible.hidden;\n", ("2339",))
    pair("type-only-import", {"a-owner.ts": CLASS},
         "import type * as ns from './a-owner';\ndeclare const instance: ns.Secret;\n"
         "const good: string = instance.value;\n", "ns.Secret.count;\n", ("1361",))
    pair("type-only-export", {"a-owner.ts": CLASS,
                              "b-barrel.ts": "export type { Secret } from './a-owner';\n"},
         "import * as ns from './b-barrel';\ndeclare const instance: ns.Secret;\n"
         "const good: string = instance.value;\n", "ns.Secret.count;\n", ("2339",))
    pair("cyclic-namespace", {"a-owner.ts": CLASS + "export * as peer from './b-peer';\n",
                              "b-peer.ts": "export * as peer from './a-owner';\n"},
         "import * as ns from './a-owner';\nconst copy = ns.peer.peer;\n"
         "const good: number = copy.Secret.count;\n", "const bad: string = copy.Secret.count;\n")
    chain = {f"d{index:02d}.ts": f"export * from './d{index + 1:02d}';\n" for index in range(40)}
    pair("long-star-chain", {"a-owner.ts": CLASS, **chain, "d40.ts": "export * from './a-owner';\n"},
         "import * as ns from './d00';\nconst good: number = ns.Secret.count;\n",
         "const bad: string = ns.Secret.count;\n")
    return result


if __name__ == "__main__":
    raise SystemExit(audit(cases()))
