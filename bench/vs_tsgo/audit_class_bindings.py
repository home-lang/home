#!/usr/bin/env python3
"""Untimed source-owned class/export binding controls for #522 and #487."""

from __future__ import annotations

from audit_globals import Case, audit


SECRET = "export declare class Secret { private key: string; value: string; }\n"


def cases() -> list[Case]:
    result = []

    def pair(family, sources, valid, invalid, expected=("2322",)):
        for order, app in (("before", "0-app.ts"), ("after", "z-app.ts")):
            for control, statements, codes in (("positive", valid, ()), ("negative", valid + invalid, expected)):
                result.append(Case(f"app-{order}/{control}", family, {**sources, app: statements}, codes))

    sources = {"a-owner.ts": SECRET, "b-other.ts": SECRET}
    for family, barrel in (
        ("local-alias", "import { Secret } from './a-owner'; export { Secret as Alias };\n"),
        ("named-barrel", "export { Secret as Alias } from './a-owner';\n"),
        ("star-barrel", "export * from './c-renamed';\n"),
        ("cyclic-barrel", "export * from './c-renamed'; export * from './e-cycle';\n"),
        ("default-alias", "export { default as Alias } from './f-default';\n"),
    ):
        pair(family, {**sources, "d-barrel.ts": barrel,
                      "c-renamed.ts": "export { Secret as Alias } from './a-owner';\n",
                      "e-cycle.ts": "export * from './d-barrel';\n",
                      "f-default.ts": "export { Secret as default } from './a-owner';\n"},
             "import { Secret } from './a-owner';\nimport { Secret as Other } from './b-other';\n"
             "import { Alias } from './d-barrel';\ndeclare const original: Secret;\n"
             "declare const alias: Alias;\ndeclare const other: Other;\n"
             "const fromAlias: Secret = alias;\nconst toAlias: Alias = original;\n",
             "const bad: Alias = other;\n")
    pair("same-file-alias", {"a-owner.ts": SECRET + "export { Secret as Alias };\n", "b-other.ts": SECRET},
         "import { Secret, Alias } from './a-owner';\nimport { Secret as Other } from './b-other';\n"
         "declare const original: Secret;\ndeclare const alias: Alias;\ndeclare const other: Other;\n"
         "const fromAlias: Secret = alias;\nconst toAlias: Alias = original;\n",
         "const bad: Alias = other;\n")
    for family, barrel, code in (
        ("type-only-export", "export type { Secret as Alias } from './a-owner';\n", "1362"),
        ("type-only-import", "import type { Secret } from './a-owner'; export { Secret as Alias };\n", "1361"),
    ):
        pair(family, {**sources, "d-barrel.ts": barrel},
             "import { Secret } from './a-owner';\nimport { Secret as Other } from './b-other';\n"
             "import { Alias } from './d-barrel';\ndeclare const original: Secret;\n"
             "declare const alias: Alias;\ndeclare const other: Other;\n"
             "const fromAlias: Secret = alias;\nconst toAlias: Alias = original;\n",
             "const bad: Alias = other;\nnew Alias();\n", ("2322", code))
    static = "export declare class Secret { private static key: string; static count: number; value: string; }\n"
    pair("static-instance-domain", {"a-owner.ts": static, "b-other.ts": static},
         "import * as first from './a-owner';\nimport * as second from './b-other';\n"
         "declare const left: first.Secret;\ndeclare const right: second.Secret;\n"
         "const leftCopy: first.Secret = right;\nconst rightCopy: second.Secret = left;\n"
         "const count: number = first.Secret.count;\n",
         "const bad: string = first.Secret.count;\n")
    pair("comment-members", {"a-owner.ts": "export declare class Visible { /* private phantom: string; */ value: string; }\n"},
         "import { Visible } from './a-owner';\nconst good: Visible = { value: 'ok' };\n",
         "const bad: Visible = { value: 1 };\n")
    pair("keyword-members", {"a-owner.ts": "export declare class Visible { 'private': string; 'static': number; }\n"},
         "import { Visible } from './a-owner';\nconst good: Visible = { private: 'ok', static: 1 };\n",
         "const bad: Visible = { private: 1, static: 1 };\n")
    pair("namespace-visibility", {"a-owner.ts": "export class Visible {}\n"
                                  "export namespace Visible { const hidden = 1; export const shown = 1; }\n"},
         "import { Visible } from './a-owner';\nconst good: number = Visible.shown;\n",
         "Visible.hidden;\n", ("2339",))
    pair("explicit-shadow", {"a-owner.ts": SECRET, "b-other.ts": SECRET,
                             "d-barrel.ts": "export * from './a-owner'; export { Secret } from './b-other';\n"},
         "import { Secret as First } from './a-owner';\nimport { Secret as Second } from './b-other';\n"
         "import { Secret } from './d-barrel';\ndeclare const first: First;\ndeclare const second: Second;\n"
         "const good: Secret = second;\n",
         "const bad: Secret = first;\n")
    return result


if __name__ == "__main__":
    raise SystemExit(audit(cases()))
