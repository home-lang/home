#!/usr/bin/env python3
"""Untimed global-declaration admission checks for #480; failures are not skipped."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
from pathlib import Path
import re
import subprocess
import tempfile

import run as bench


@dataclass(frozen=True)
class Case:
    name: str
    family: str
    files: dict[str, str]
    expected: tuple[str, ...]
    # None keeps the historical all-files root set. Explicit roots exercise
    # discovery without granting one compiler a different source graph.
    roots: tuple[str, ...] | None = None
    check_js: bool = False


METHODS = "interface Methods { identity(value: string): string; }\n"
VARIABLE = "declare var methods: Methods;\n"
GOOD = "const good: string = methods.identity('ok');\n"
BAD = "const bad: number = methods.identity('ok');\nmethods.identity(1);\nmethods.missing();\n"
GENERIC = "interface DeferredConstructor { identity<T>(value: T): T; }\n"
GENERIC_VARIABLE = "declare var Deferred: DeferredConstructor;\n"
GENERIC_GOOD = "const good: string = Deferred.identity('ok');\n"
GENERIC_BAD = "const bad: number = Deferred.identity('ok');\n"
COUNT = "interface Methods { count(value: number): number; }\n"
MERGED_GOOD = GOOD + "const count: number = methods.count(1);\n"
MERGED_BAD = "const bad: number = methods.identity('ok');\nmethods.count('bad');\nmethods.missing();\n"
CYCLIC_LEFT = "interface Left { right: Right; }\ndeclare var left: Left;\n"
CYCLIC_RIGHT = "interface Right { value: string; left: Left; }\n"
CYCLIC_GOOD = "const goodValue: string = left.right.value;\nconst goodCycle: Left = left.right.left;\n"
CYCLIC_BAD = "const badValue: number = left.right.value;\n"
CODES = ("2322", "2345", "2339")


def cases(family: str | None = None) -> list[Case]:
    result = []

    def pair(name, group, declarations, valid, invalid, expected, *, suffix="", siblings=None):
        variants = (("script", ""), ("module", "")) if group == "same-file" else (
            ("script", "before"), ("script", "after")
        )
        for scope, order in variants:
            prefix = "export {};\n" if scope == "module" else ""
            shared = dict(siblings or {})
            if order:
                filename = "a-globals.d.ts" if order == "before" else "z-globals.d.ts"
                shared[filename] = shared.pop("globals.d.ts")
            if scope == "module":
                # A same-named global must not erase or replace module-local types.
                shared["globals.d.ts"] = "interface Methods { identity(value: number): number; }\n"
            for control, statements, codes in (("positive", valid, ()), ("negative", valid + invalid, expected)):
                files = {**shared, "app.ts": prefix + declarations + statements + suffix}
                variant = f"{scope}/{order}" if order else scope
                result.append(Case(f"{name}/{variant}/{control}", group, files, codes))

    pair("ordinary", "same-file", METHODS + VARIABLE, GOOD, BAD, CODES)
    pair("type-and-value", "same-file", "const Methods = 1;\n" + METHODS + VARIABLE, GOOD, BAD, CODES)
    pair("forward", "same-file", VARIABLE, GOOD, BAD, CODES, suffix=METHODS)
    pair("generic-static", "same-file", GENERIC + GENERIC_VARIABLE, GENERIC_GOOD, GENERIC_BAD, ("2322",))
    pair("merged", "same-file", METHODS + COUNT + VARIABLE, MERGED_GOOD, MERGED_BAD, CODES)
    pair("alias", "same-file", METHODS + "type Alias = Methods;\ndeclare var methods: Alias;\n",
         GOOD, "const bad: number = methods.identity('ok');\nmethods.identity(1);\n", ("2322", "2345"))
    pair("sibling-interface", "cross-file", VARIABLE, GOOD, BAD, CODES, siblings={"globals.d.ts": METHODS})
    pair("sibling-type-and-local-value", "cross-file", "const Methods = 1;\n" + VARIABLE,
         GOOD, BAD, CODES, siblings={"globals.d.ts": METHODS})
    pair("sibling-generic", "cross-file", GENERIC_VARIABLE, GENERIC_GOOD, GENERIC_BAD, ("2322",),
         siblings={"globals.d.ts": GENERIC})
    pair("sibling-variable", "cross-file", "", GOOD, BAD, CODES, siblings={"globals.d.ts": METHODS + VARIABLE})
    for kind in ("let", "const"):
        pair(f"sibling-{kind}", "cross-file", "", "const good: number = lexicalValue;\n",
             "const bad: string = lexicalValue;\n", ("2322",),
             siblings={"globals.d.ts": f"declare {kind} lexicalValue: number;\n"})
    pair("sibling-global-this", "cross-file", "", "const good: number = globalThis.sharedValue;\n",
         "const bad: string = globalThis.sharedValue;\n", ("2322",),
         siblings={"globals.d.ts": "declare var sharedValue: number;\n"})
    pair("sibling-merge", "cross-file", METHODS + VARIABLE, MERGED_GOOD, MERGED_BAD, CODES,
         siblings={"globals.d.ts": COUNT})
    for order, roots in (
        ("before", ("left.d.ts", "right.d.ts", "app.ts")),
        ("after", ("app.ts", "right.d.ts", "left.d.ts")),
    ):
        files = {"left.d.ts": CYCLIC_LEFT, "right.d.ts": CYCLIC_RIGHT}
        for control, statements, expected in (
            ("positive", CYCLIC_GOOD, ()),
            ("negative", CYCLIC_GOOD + CYCLIC_BAD, ("2322",)),
        ):
            result.append(Case(
                f"sibling-cycle/script/{order}/{control}",
                "cross-file",
                {**files, "app.ts": statements},
                expected,
                roots=roots,
            ))
    return [case for case in result if family is None or case.family == family]


def diagnostics_match(result: subprocess.CompletedProcess[str], expected: tuple[str, ...]) -> bool:
    output = result.stdout + result.stderr
    codes = re.findall(r"error TS(\d+):", output)
    # A crash or usage error must not count as rejecting an invalid program.
    if result.returncode not in (0, 1, 2):
        return False
    if not expected:
        return result.returncode == 0 and not output
    return result.returncode != 0 and sorted(codes) == sorted(expected)


def project_config(case: Case) -> str:
    config = json.loads(bench.shared_config(check_js=case.check_js))
    del config["include"]
    # Explicit roots make the declaration-before/after-app checks independent
    # of directory traversal or glob ordering in the three compilers.
    roots = sorted(case.files) if case.roots is None else case.roots
    config["files"] = ["src/lib.d.ts"] + [f"src/{name}" for name in roots]
    return json.dumps(config, indent=2) + "\n"


def audit(selected: list[Case]) -> int:
    commands = bench.compiler_commands()
    print(bench.verified_compiler_versions(commands), flush=True)
    failures = 0
    for case in selected:
        # A fresh project per case prevents stale declarations from leaking
        # between tests. Every compiler receives exactly these same files.
        with tempfile.TemporaryDirectory(prefix="home-global-audit-") as temporary:
            project = Path(temporary)
            bench.write(project / "tsconfig.json", project_config(case))
            bench.generate_minimal_lib(project)
            for filename, source in case.files.items():
                bench.write(project / "src" / filename, source)
            for compiler, command in commands.items():
                result = subprocess.run(command + ["-p", str(project / "tsconfig.json")], capture_output=True, text=True)
                matched = diagnostics_match(result, case.expected)
                codes = re.findall(r"error TS(\d+):", result.stdout + result.stderr)
                print(f"{'PASS' if matched else 'FAIL'} {case.family}/{case.name} {compiler}: {codes}", flush=True)
                if not matched:
                    failures += 1
                    print(result.stdout + result.stderr, flush=True)
    print(f"{len(selected) * len(commands)} checks; {failures} failures (untimed)", flush=True)
    return int(failures != 0)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--family", choices=("same-file", "cross-file"), help="default: audit both families")
    args = parser.parse_args()
    return audit(cases(args.family))


if __name__ == "__main__":
    raise SystemExit(main())
