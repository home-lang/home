#!/usr/bin/env python3
"""Untimed ownership and typing of exported variable lists for #538 / #537."""

from audit_globals import Case, audit


def cases() -> list[Case]:
    result = []
    for declaration in ("const", "let", "var", "declare-var"):
        statement = ("export declare var first: number, second: string;\n" if declaration == "declare-var"
                     else f"export {declaration} first: number = 1, second: string = 'text';\n")
        owner = statement + "const hidden: number = 0;\n"
        for placement in ("named", "namespace", "barrel-named", "barrel-namespace"):
            files = {"a-owner.ts": owner}
            target = "a-owner"
            if placement.startswith("barrel-"):
                files["b-middle.ts"] = "export * from './a-owner';\n"
                files["c-barrel.ts"] = "export * from './b-middle';\n"
                target = "c-barrel"
            if placement.endswith("namespace"):
                imports = f"import * as values from './{target}';\n"
                first, second = "values.first", "values.second"
            else:
                imports = f"import {{ first as numeric, second as selected }} from './{target}';\n"
                first, second = "numeric", "selected"
            positive = imports + f"const numberValue: number = {first};\nconst stringValue: string = {second};\n"
            controls = (
                ("positive", positive, ()),
                ("wrong-type", positive + f"const bad: number = {second};\n", ("2322",)),
                ("hidden", positive + f"import {{ hidden }} from './{target}';\n", ("2305" if target == "c-barrel" else "2459",)),
            )
            for order, app in (("before", "0-app.ts"), ("after", "z-app.ts")):
                for control, text, expected in controls:
                    result.append(Case(f"{placement}/app-{order}/{control}", declaration, {**files, app: text}, expected))
    return result


if __name__ == "__main__":
    raise SystemExit(audit(cases()))
