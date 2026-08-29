#!/usr/bin/env python3
"""Untimed exported generic types and factory contracts for #534 / #487."""

from audit_globals import Case, audit


BOX = "export interface Box<T> { readonly value: T; }\n"
FACTORY = "export function make<T>(value: T): Box<T> { return { value }; }\n"


def cases() -> list[Case]:
    result = []

    def pair(family, owner, valid, invalid, code):
        for placement in ("local", "named", "namespace", "barrel-named", "barrel-namespace"):
            sources = {"a-owner.ts": owner}
            if placement == "local":
                sources["a-owner.ts"] = "export {};\n"
                imports, box, make = owner, "Box", "make"
            else:
                target = "a-owner"
                if placement.startswith("barrel-"):
                    sources["b-middle.ts"] = "export * from './a-owner';\n"
                    sources["c-barrel.ts"] = "export { Box, make } from './b-middle';\n"
                    target = "c-barrel"
                if placement.endswith("namespace"):
                    imports, box, make = f"import * as ns from './{target}';\n", "ns.Box", "ns.make"
                else:
                    imports, box, make = f"import {{ Box as RemoteBox, make as build }} from './{target}';\n", "RemoteBox", "build"
            positive = imports + valid.replace("$Box", box).replace("$make", make)
            negative = positive + invalid.replace("$Box", box).replace("$make", make)
            for order, app in (("before", "0-app.ts"), ("after", "z-app.ts")):
                for control, text, expected in (("positive", positive, ()), ("negative", negative, (code,))):
                    result.append(Case(f"{placement}/app-{order}/{control}", family, {**sources, app: text}, expected))

    pair("annotated-interface", BOX + FACTORY,
         "declare const value: $Box<string>;\nconst good: string = value.value;\n",
         "const bad: number = value.value;\n", "2322")
    pair("inferred-factory-return", BOX + FACTORY,
         "const value = $make('text');\nconst good: string = value.value;\n",
         "const bad: number = value.value;\n", "2322")
    pair("missing-member", BOX + FACTORY,
         "const value = $make(1);\nconst good: number = value.value;\n",
         "value.missing;\n", "2339")
    pair("readonly-result", BOX + FACTORY,
         "const value = $make(1);\nconst good: number = value.value;\n",
         "value.value = 2;\n", "2540")
    pair("explicit-call-argument", BOX + FACTORY,
         "const value = $make<string>('text');\nconst good: string = value.value;\n",
         "$make<string>(1);\n", "2345")
    pair("constraint", BOX + "export function make<T extends { size: number }>(value: T): Box<T> { return { value }; }\n",
         "const value = $make({ size: 1 });\nconst good: number = value.value.size;\n",
         "$make<string>('text');\n", "2344")
    signature = BOX + "export function make<T>(value: T, label: string): Box<T> { return { value }; }\n"
    pair("required-arity", signature,
         "const value = $make('text', 'label');\nconst good: string = value.value;\n",
         "$make('text');\n", "2554")
    pair("ordinary-argument", signature,
         "const value = $make('text', 'label');\nconst good: string = value.value;\n",
         "$make('text', 123);\n", "2345")
    pair("dependent-default", BOX + "export declare function make<T = string, U = T[]>(): Box<U>;\n",
         "const value = $make();\nconst good: string[] = value.value;\n",
         "const bad: number[] = value.value;\n", "2322")
    pair("rest-argument", BOX + "export function make<T>(...values: T[]): Box<T[]> { return { value: values }; }\n",
         "const value = $make('first', 'second');\nconst good: string[] = value.value;\n",
         "const bad: number[] = value.value;\n", "2322")
    pair("captured-factory", BOX + FACTORY,
         "const factory = $make;\nconst value = factory('text');\nconst good: string = value.value;\n",
         "const bad: number = value.value;\n", "2322")
    # Consumer-local type names must not rebind the source factory's return.
    # A nested scope keeps the local placement valid without a duplicate Box.
    pair("owner-name-collision", BOX + FACTORY,
         "function consume() {\ninterface Box<T> { value: number; }\n"
         "const value = $make('text');\nconst good: string = value.value;\nreturn value;\n}\n"
         "const selected = consume();\n",
         "const bad: number = selected.value;\n", "2322")
    return result


if __name__ == "__main__":
    raise SystemExit(audit(cases()))
