#!/usr/bin/env python3
"""Untimed recursive-generic consumers, local and imported, for #524."""

from audit_globals import Case, audit


GROWING = "type Link<X> = { item: X; next: Link<X[]> };\n"
BOX = "export declare class Box<T> { value: Link<T>; }\n"


def cases() -> list[Case]:
    result = []

    def pair(family, declarations, valid, invalid, *, mirror=False):
        owner = declarations + BOX
        if mirror:
            owner += "type Mirror<X> = { item: X; next: Mirror<X[]> };\n"
            owner += "export declare class MirrorBox<T> { value: Mirror<T>; }\n"
        for placement in ("local", "named", "namespace"):
            if placement == "local":
                imports = owner
                sources = {"a-owner.ts": "export {};\n"}
                prefix = ""
            elif placement == "named":
                names = "Box, MirrorBox" if mirror else "Box"
                imports = f"import {{ {names} }} from './a-owner';\n"
                sources = {"a-owner.ts": owner}
                prefix = ""
            else:
                imports = "import * as ns from './a-owner';\n"
                sources = {"a-owner.ts": owner}
                prefix = "ns."
            positive = imports + "declare const value: " + prefix + "Box<string>;\n" + valid
            negative = positive + invalid
            for order, app in (("before", "0-app.ts"), ("after", "z-app.ts")):
                for control, text, expected in (("positive", positive, ()), ("negative", negative, ("2322",))):
                    text = text.replace("$Box", prefix + "Box").replace("$Mirror", prefix + "MirrorBox")
                    result.append(Case(f"{placement}/app-{order}/{control}", family,
                                       {**sources, app: text}, expected))

    pair("fixed-depth-8", "type Link<X> = { item: X; next: Link<X> };\n",
         "const selected = value.value" + ".next" * 8 + ".item;\nconst good: string = selected;\n",
         "const bad: number = selected;\n")
    for depth in (1, 4, 12):
        pair(f"growing-array-depth-{depth}", GROWING,
             "const selected = value.value" + ".next" * depth + ".item;\n"
             + "const good: string" + "[]" * depth + " = selected;\n",
             "const bad: number" + "[]" * depth + " = selected;\n")
    pair("growing-object-depth-4", "type Link<X> = { item: X; next: Link<{ value: X }> };\n",
         "const selected = value.value" + ".next" * 4 + ".item" + ".value" * 4 + ";\n"
         "const good: string = selected;\n", "const bad: number = selected;\n")
    pair("mutual-growing-depth-4",
         "type Link<X> = { item: X; next: Other<X[]> };\n"
         "type Other<Y> = { item: Y; next: Link<Y[]> };\n",
         "const selected = value.value.next.next.next.next.item;\nconst good: string[][][][] = selected;\n",
         "const bad: number[][][][] = selected;\n")
    pair("flipped-parameters", "type Pair<A, B> = { item: A; next: Pair<B, A> };\ntype Link<X> = Pair<X, number>;\n",
         "const first: number = value.value.next.item;\nconst second: string = value.value.next.next.item;\n",
         "const bad: string = value.value.next.item;\n")
    pair("recursive-return", "type Link<X> = { item: X; next(): Link<X[]> };\n",
         "const selected = value.value.next().next().item;\nconst good: string[][] = selected;\n",
         "const bad: number[][] = selected;\n")
    pair("recursive-array-member", "type Link<X> = { item: X; children: Link<X[]>[] };\n",
         "const selected = value.value.children[0].children[0].item;\nconst good: string[][] = selected;\n",
         "const bad: number[][] = selected;\n")
    pair("recursive-optional-union", "type Link<X> = { item: X; next: Link<X[]> | undefined };\n",
         "const selected = value.value.next?.next?.item;\nconst good: string[][] | undefined = selected;\n",
         "const bad: number[][] | undefined = selected;\n")
    pair("recursive-indexed-access", GROWING,
         "type Selected = $Box<string>['value']['next']['item'];\ndeclare const selected: Selected;\n"
         "const good: string[] = selected;\n", "const bad: number[] = selected;\n")
    pair("recursive-keyof", GROWING,
         "type Keys = keyof $Box<string>['value']['next'];\nconst item: Keys = 'item';\nconst next: Keys = 'next';\n",
         "const bad: Keys = 'missing';\n")
    pair("recursive-inference", GROWING,
         "declare function read<T>(input: { item: T }): T;\nconst selected = read(value.value.next.next);\n"
         "const good: string[][] = selected;\n", "const bad: number[][] = selected;\n")
    pair("recursive-destructuring", GROWING,
         "const { item } = value.value.next;\nconst good: string[] = item;\n",
         "const bad: number[] = item;\n")
    pair("finite-structural-target", GROWING,
         "const good: { item: string; next: { item: string[] } } = value.value;\n",
         "const bad: { item: string; next: { item: number[] } } = value.value;\n")
    pair("distinct-recursive-origins", GROWING,
         "const good: $Mirror<string> = value;\n",
         "const bad: $Mirror<number> = value;\n", mirror=True)
    return result


if __name__ == "__main__":
    raise SystemExit(audit(cases()))
