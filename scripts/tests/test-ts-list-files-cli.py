#!/usr/bin/env python3
"""Compare syntax-only file discovery with native tsc, under run-bounded.pl.

Each invocation owns an isolated fixture. Input hashes and the complete file
set must remain unchanged: --listFilesOnly must never emit, even with emit
enabled. The Program unit regression separately enforces the phase boundary.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile


GLOBALS = "\n".join(f"interface {name} {{}}" for name in (
    "Array<T>", "Boolean", "CallableFunction", "Function", "IArguments",
    "NewableFunction", "Number", "Object", "RegExp", "String",
)) + "\n"


def cases() -> list[dict]:
    result = []

    def add(name, files, options=None, codes=(), controls=(), roots=None, libraries=False, expected_graph=None, flags=(), semantic=False):
        result.append(dict(name=name, files=files, options=options or {},
                           codes=list(codes), controls=list(controls),
                           roots=roots or [next(iter(files))], libraries=libraries,
                           expected_graph=expected_graph, flags=list(flags), semantic=semantic))

    for no_emit in (False, True):
        add(f"semantic-errors-no-emit-{no_emit}",
            {"main.ts": "export const wrong: number = 'text';\n"},
            {"noEmit": no_emit}, controls=(2322,))
    add("syntax-error", {"main.ts": "export const broken = ;\n"}, codes=(1109,))
    # Native syntactic diagnostics exclude source grammar errors (1155/1016)
    # but include syntax that TypeScript forbids specifically in JavaScript.
    add("const-without-initializer", {"main.ts": "export const missing;\n"},
        controls=(1155, 7005))
    add("optional-before-required", {"main.ts": "export function call(first?:string, second:string){}\n"},
        controls=(1016,))
    add("grammar-with-syntax", {"main.ts": "export const missing; const broken = ;\n"},
        codes=(1109,), controls=(1109,))
    add("comma-initializer-syntax", {"main.ts": "export const first=1, broken=;\n"},
        codes=(1109,), controls=(1109,))
    add("simple-syntax-normal-control", {"main.ts": "export const broken = ;\n"},
        codes=(1109,), controls=(1109,))
    for name, source, code in (
        ("js-type-annotation", "export const value: number = 1;", 8010),
        ("js-parameter-property", "export class C {constructor(public value){}}", 8012),
        ("js-accessibility-modifier", "export class C {public value=1;}", 8009),
    ):
        add(name, {"main.js": source + "\n"}, {"allowJs": True, "noEmit": True},
            codes=(code,), controls=(code,))
    for name, source, codes in (
        ("js-function-annotations", 'export function call(value:number):string {return "";}', (8010, 8010)),
        ("js-field-annotation", "export class C { field:string; }", (8010,)),
        ("js-nested-function-annotation", 'export const f: (value:number)=>string = (v)=>"";', (8010,)),
        ("js-type-alias-outer-only", "export type A={ value:number; };", (8008,)),
        ("js-ignore-cannot-suppress-syntax", "// @ts-ignore\nexport const value:number=1;", (8010,)),
    ):
        add(name, {"main.js": source + "\n"}, {"allowJs": True, "noEmit": True},
            codes=codes, controls=codes)
    add("option-error", {"main.ts": "export const wrong: number = 'text';\n"},
        {"allowJs": False, "checkJs": True}, codes=(5052,))
    add("syntax-before-options", {"main.ts": "export const broken = ;\n"},
        {"allowJs": False, "checkJs": True}, codes=(1109,))
    add("import-closure", {
        "main.ts": "import { value } from './helper'; export const wrong: string = value;\n",
        "helper.ts": "export { value } from './nested/value';\n",
        "nested/value.ts": "export const value: number = 42;\n",
    }, controls=(2322,))
    add("independent-root-order", {"first.ts": "export {};", "second.ts": "export {};"},
        roots=["second.ts", "first.ts"])
    add("diamond-import-order", {
        "main.ts": "import './right'; import './left';",
        "right.ts": "import './shared'; export {};",
        "left.ts": "import './shared'; export {};",
        "shared.ts": "export {};",
    })
    add("cyclic-import-order", {
        "main.ts": "import './first';",
        "first.ts": "import './second'; export {};",
        "second.ts": "import './first'; export {};",
    })
    add("path-reference-before-import", {
        "main.ts": '/// <reference path="./pre.d.ts" />\nimport "./dep";',
        "pre.d.ts": "declare const pre: number;",
        "dep.ts": "export {};",
    })
    add("path-reference-before-written-type-reference", {
        "main.ts": '/// <reference types="kit" />\n/// <reference path="./pre.d.ts" />\nimport "./dep";',
        "pre.d.ts": "declare const pre: number;",
        "dep.ts": "export {};",
        "node_modules/@types/kit/index.d.ts": "interface Kit {}",
    }, {"types": []})
    add("configured-types-after-source-roots", {
        "main.ts": "import './dep';",
        "dep.ts": "export {};",
        "node_modules/@types/kit/index.d.ts": "interface Kit {}",
    }, {"types": ["kit"]})
    add("imported-helper-before-written-import", {
        "main.ts": "import './dep'; export async function value() {}",
        "dep.ts": "export {};",
        "node_modules/tslib/index.d.ts": "export {};",
    }, {"importHelpers": True, "types": []})
    add("jsx-runtime-before-written-import", {
        "main.tsx": "import './dep'; export const element = <missing />;",
        "dep.ts": "export {};",
        "node_modules/react/jsx-runtime.d.ts": "export namespace JSX { interface Element {} }",
    }, {"jsx": "react-jsx", "types": []})
    add("library-priority-before-source", {"main.ts": "export {};"},
        {"noLib": False, "lib": ["es2015.promise", "es5"], "types": []}, libraries=True)
    add("library-reference-priority", {
        "main.ts": '/// <reference lib="es2015.promise" />\nexport {};',
    }, {"noLib": False, "lib": ["es5"], "types": []}, libraries=True)
    add("no-lib-suppresses-lib-reference", {
        "main.ts": '/// <reference lib="es2015.promise" />\nexport {};',
    }, {"noLib": True, "types": []}, libraries=True)
    add("no-resolve-import", {
        "main.ts": "import './dep'; export {};", "dep.ts": "export {};",
    }, {"noResolve": True, "types": []}, expected_graph=["globals.d.ts", "main.ts"])
    add("no-resolve-path-reference", {
        "main.ts": '/// <reference path="./pre.d.ts" />\nexport {};',
        "pre.d.ts": "interface Pre {}",
    }, {"noResolve": True, "types": []}, expected_graph=["globals.d.ts", "main.ts"])
    add("no-resolve-type-reference", {
        "main.ts": '/// <reference types="kit" />\nexport {};',
        "node_modules/@types/kit/index.d.ts": "interface Kit {}",
    }, {"noResolve": True, "types": []}, expected_graph=["globals.d.ts", "main.ts"])
    add("no-resolve-keeps-explicit-root-import-binding", {
        "main.ts": "import { value } from './dep'; export const wrong: string = value;",
        "dep.ts": "export const value: number = 1;",
    }, {"noResolve": True, "types": []}, roots=["main.ts", "dep.ts"], controls=(2322,))
    add("no-resolve-keeps-library-references", {
        "main.ts": '/// <reference lib="es2015.promise" />\nexport {};',
    }, {"noResolve": True, "noLib": False, "lib": ["es5"], "types": []}, libraries=True)
    add("no-lib-keeps-type-references", {
        "main.ts": '/// <reference types="kit" />\nexport {};',
        "node_modules/@types/kit/index.d.ts": '/// <reference lib="es2015.promise" />\ninterface Kit {}',
    }, {"noLib": True, "types": []}, libraries=True)
    add("no-resolve-cli-false-overrides-config", {
        "main.ts": "import './dep'; export {};", "dep.ts": "export {};",
    }, {"noResolve": True, "types": []}, flags=("--NORESOLVE", "false"))
    add("no-resolve-cli-true-overrides-config", {
        "main.ts": "import './dep'; export {};", "dep.ts": "export {};",
    }, {"noResolve": False, "types": []}, flags=("--noResolve", "true"),
        expected_graph=["globals.d.ts", "main.ts"])
    add("no-lib-cli-false-overrides-config", {"main.ts": "export {};"},
        {"noLib": True, "lib": ["es5"], "types": []}, libraries=True, flags=("--NOLIB", "false"))
    add("no-lib-cli-true-overrides-config", {
        "main.ts": '/// <reference lib="es2015.promise" />\nexport {};',
    }, {"noLib": False, "types": []}, libraries=True, flags=("--noLib", "true"))
    add("no-resolve-rejects-unadmitted-module", {
        "main.ts": "import { value } from './dep'; export const wrong: string = value;",
        "dep.ts": "export const value: number = 1;",
    }, {"noResolve": True, "types": []}, controls=(2307,),
        expected_graph=["globals.d.ts", "main.ts"])
    for mode, options in (("automatic", {"noResolve": True}),
                          ("configured", {"noResolve": True, "types": ["kit"]})):
        add("no-resolve-" + ("suppresses-" if mode == "automatic" else "keeps-") + mode + "-type-roots", {
            "main.ts": "export {};",
            "node_modules/@types/kit/index.d.ts": "interface Kit {}",
        }, options, expected_graph=["globals.d.ts", "main.ts"] if mode == "automatic" else None)
    add("no-resolve-rejects-unadmitted-import-type", {
        "main.ts": "export type Value = import('./dep').Value; declare const value: Value; export const wrong: string = value;",
        "dep.ts": "export type Value = number;",
    }, {"noResolve": True, "types": []}, controls=(2307,), expected_graph=["globals.d.ts", "main.ts"])
    for mode, source in (("owner", "export { value } from './leaf';"),
                         ("import", "import { value } from './leaf'; export { value };")):
        add("no-resolve-rejects-unadmitted-reexport-" + mode, {
            "main.ts": "import { value } from './dep'; export const wrong: string = value;",
            "dep.ts": source,
            "leaf.ts": "export const value: number = 1;",
        }, {"noResolve": True, "types": []}, roots=["main.ts", "dep.ts"], controls=(2307,),
            expected_graph=["globals.d.ts", "main.ts", "dep.ts"])
    for name in ("package.json", "nested/tsconfig.json", "data.json"):
        add("json-module-" + name.replace("/", "-"), {
            "main.ts": "import data from './" + name + "'; export { data };",
            name: '{"name":"fixture","items":[1,true,null],"nested":{"version":2}}',
        }, {"resolveJsonModule": True})
    add("json-module-double-quotes-required", {
        "main.ts": "import data from './data.json'; export { data };",
        "data.json": "{\"value\": 'text'}",
    }, {"resolveJsonModule": True}, codes=(1327,))
    add("contextual-keyword-parameter-declaration", {
        "main.ts": "import type { Redis } from './owner'; export type Client = Redis;",
        "owner.d.ts": "export declare class Redis { duplicate(override?: { port?: number }): Redis; }",
    })
    add("no-resolve-reexport-retains-known-missing-name", {
        "main.ts": "import { absent } from './dep'; export { absent };",
        "dep.ts": "export { value } from './leaf';",
        "leaf.ts": "export const value = 1;",
    }, {"noResolve": True, "types": []}, roots=["main.ts", "dep.ts"], controls=(2305, 2307),
        expected_graph=["globals.d.ts", "main.ts", "dep.ts"])
    for expression, mode in (("import data from './data.json'; export { data };", "value"),
                             ("export type Data = typeof import('./data.json');", "type")):
        for no_resolve in (False, True):
            files = {"main.ts": expression}
            if no_resolve:
                files["data.json"] = '{"value":1}'
            add("json-" + mode + ("-excluded" if no_resolve else "-missing"), files,
                {"resolveJsonModule": True, "noResolve": no_resolve, "types": []}, controls=(2307,),
                expected_graph=["globals.d.ts", "main.ts"])
    add("no-resolve-javascript-remains-untyped", {
        "main.ts": "import { value } from './dep.js'; export { value };",
        "dep.js": "export const value = 1;",
    }, {"noResolve": True, "allowJs": True, "types": []}, controls=(7016,),
        expected_graph=["globals.d.ts", "main.ts"])
    add("no-resolve-namespace-import", {
        "main.ts": "import * as ns from './dep'; export const wrong: string = ns.value;",
        "dep.ts": "export const value: number = 1;",
    }, {"noResolve": True, "types": []}, controls=(2307,), expected_graph=["globals.d.ts", "main.ts"])
    for mode, source, name in (("namespace", "export * as ns from './leaf';", "ns"),
                               ("star-present", "export * from './leaf';", "value"),
                               ("star-unknown", "export * from './leaf';", "absent")):
        expression = name + ".value" if name == "ns" else name
        add("no-resolve-reexport-" + mode, {
            "main.ts": "import { " + name + " } from './dep'; export const wrong: string = " + expression + ";",
            "dep.ts": source,
            "leaf.ts": "export const value: number = 1;",
        }, {"noResolve": True, "types": []}, roots=["main.ts", "dep.ts"],
            controls=(2307,) if mode == "namespace" else (2305, 2307),
            expected_graph=["globals.d.ts", "main.ts", "dep.ts"])
    json_globals = GLOBALS + "interface ImportAttributes { [key: string]: string; }\n"
    for resolution, module in (("bundler", "ESNext"), ("nodenext", "NodeNext")):
        for enabled in (None, False, True):
            for attributes in (False, True):
                options = {"module": module, "moduleResolution": resolution, "types": []}
                if enabled is not None:
                    options["resolveJsonModule"] = enabled
                active = enabled is not False
                codes = () if active else (2732,)
                if active and resolution == "nodenext" and not attributes:
                    codes = (1543,)
                add(f"json-option-{resolution}-{enabled}-attributes-{attributes}", {
                    "main.ts": "import data from './data.json'" + (" with { type: 'json' }" if attributes else "") + "; export { data };",
                    "data.json": '{"value":1}', "package.json": '{"type":"module"}',
                    "globals.d.ts": json_globals,
                }, options, controls=codes, semantic=True,
                    expected_graph=["globals.d.ts", "main.ts"] + (["data.json"] if active else []))
    add("json-option-node16-default", {
        "main.ts": "import data from './data.json'; export { data };",
        "data.json": '{"value":1}', "package.json": '{"type":"module"}',
    }, {"module": "Node16", "moduleResolution": "node16", "types": []}, controls=(2732,),
        expected_graph=["globals.d.ts", "main.ts"])
    for spelling, enabled, flag in (("disabled", False, "--resolveJsonModule"), ("enabled", True, "--resolveJsonModule"),
                                    ("uppercase", False, "--RESOLVEJSONMODULE"), ("single-dash", True, "-resolveJsonModule")):
        add("json-cli-" + spelling, {
            "main.ts": "import data from './data.json'; export { data };", "data.json": '{"value":1}',
        }, {"resolveJsonModule": not enabled, "types": []}, controls=() if enabled else (2732,),
            flags=(flag, "true" if enabled else "false"), semantic=True,
            expected_graph=["globals.d.ts", "main.ts"] + (["data.json"] if enabled else []))
    add("unresolved-import", {"main.ts": "import { absent } from './absent'; export { absent };\n"},
        controls=(2307,))
    add("declaration-emit-enabled", {"main.ts": "export const wrong: number = 'text';\n"},
        {"declaration": True, "declarationMap": True, "sourceMap": True,
         "outDir": "output", "declarationDir": "types"}, controls=(2322,))
    add("javascript-input-overwrite", {"main.js": "export const value = 42;\n"},
        {"allowJs": True}, codes=(5055,))
    add("javascript-no-emit", {"main.js": "// @ts-check\n/** @type {number} */\nexport const value = 'text';\n"},
        {"allowJs": True, "checkJs": True, "noEmit": True}, controls=(2322,))
    add("tsx-preserve", {"main.tsx": "export const element = <missing />;\n"},
        {"jsx": "preserve"})
    # A shared alias graph should be parsed/bound without materializing its
    # structural expansions or display names merely to enumerate the files.
    graph = {"main.ts": "import type { Shape } from './graph'; export const wrong: number = 'text'; declare const shape: Shape;\n"}
    graph["graph.ts"] = "type Layer0<T> = { value: T };\n" + "\n".join(
        f"type Layer{i}<T> = {{ left: Layer{i-1}<T>; right: Layer{i-1}<T> }};"
        for i in range(1, 97)
    ) + "\nexport type Shape = Layer96<string>;\n"
    add("shared-generic-graph", graph, controls=(2322,))
    return result


def hashes(directory: Path) -> dict[str, str]:
    return {str(p.relative_to(directory)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(directory.rglob("*")) if p.is_file()}


def invoke(command: list[str], directory: Path) -> dict:
    process = subprocess.Popen(command, cwd=directory, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=90)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        stdout, stderr = process.communicate()
        raise AssertionError({"command": command, "timeout": True,
                              "stdout": stdout, "stderr": stderr})
    return dict(command=command, exit=process.returncode, stdout=stdout, stderr=stderr)



def reference_library_package(reference: Path) -> Path:
    """Find libraries for both JS installations and native TypeScript wrappers."""
    package = reference.resolve().parent.parent
    if (package / "lib/lib.es5.d.ts").is_file():
        return package
    # TypeScript 7's official launcher resolves the optional platform package
    # using the architecture of Node itself. Reuse it instead of guessing
    # from the Python host (which can differ under Rosetta).
    launcher = package / "lib/getExePath.js"
    assert launcher.is_file(), "Reference compiler's installed standard libraries are missing"
    result = subprocess.run([
        "node", "--input-type=module", "-e",
        "const {default: getExePath} = await import(process.argv[1]); process.stdout.write(getExePath());",
        launcher.as_uri(),
    ], check=True, capture_output=True, text=True, timeout=10)
    native = Path(result.stdout.strip()).resolve(strict=True)
    package = native.parent.parent
    assert (package / "package.json").is_file() and (package / "lib/lib.es5.d.ts").is_file(), native
    return package



def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--reference-only", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    assert args.reference_only or args.home, "--home is required unless --reference-only"
    root = args.output.resolve() if args.output else Path(tempfile.mkdtemp(prefix="home-list-files-"))
    root.mkdir(parents=True, exist_ok=True)
    engines = [("reference", args.reference.resolve())]
    if not args.reference_only:
        engines.append(("home", args.home.resolve()))
    reference_package = reference_library_package(args.reference)
    library_inputs = {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
                      for path in sorted((reference_package / "lib").glob("lib*.d.ts"))}
    assert library_inputs and (reference_package / "package.json").is_file()

    def listed_paths(stdout: str, directory: Path) -> list[str]:
        paths = []
        for line in stdout.splitlines():
            if re.search(r"error TS\d+:", line) or not Path(line).is_absolute():
                continue
            path = Path(line)
            if path.is_relative_to(directory):
                paths.append(str(path.relative_to(directory)))
            else:
                # Both executables must select the same pinned installed libs.
                assert str(path) in library_inputs, line
                paths.append(str(path))
        return paths

    summary = dict(passed=False, reference_only=args.reference_only, observations=[],
                   binaries={name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in engines},
                   library_inputs=library_inputs)
    assert not (root / "summary.json").exists(), "Existing listing evidence must not be overwritten"

    def checkpoint() -> None:
        # The outer guard may terminate this process before finally runs.
        # Keep every completed observation and identify the pending compiler.
        temporary = root / "summary.json.tmp"
        temporary.write_text(json.dumps(summary, indent=2) + "\n")
        temporary.replace(root / "summary.json")

    checkpoint()
    try:
        for case in cases():
            paired = []
            for engine, executable in engines:
                directory = root / case["name"] / engine
                directory.mkdir(parents=True, exist_ok=False)
                files = {**({} if case["libraries"] else {"globals.d.ts": GLOBALS}), **case["files"]}
                if case["libraries"]:
                    (directory / "node_modules").mkdir()
                    (directory / "node_modules/typescript").symlink_to(reference_package, target_is_directory=True)
                config = dict(compilerOptions={"noLib": True, "target": "ESNext", "module": "ESNext",
                              "moduleResolution": "bundler", "strict": True, **case["options"]},
                              files=[*(["globals.d.ts"] if not case["libraries"] else []), *case["roots"]])
                files["tsconfig.json"] = json.dumps(config, indent=2) + "\n"
                for name, source in files.items():
                    path = directory / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text(source)
                before = hashes(directory)
                summary["pending"] = dict(case=case["name"], engine=engine, mode="list-files-only")
                checkpoint()
                record = invoke([str(executable), "-p", "tsconfig.json", "--pretty", "false", "--listFilesOnly", *case["flags"]], directory)
                record.update(case=case["name"], engine=engine, input_hashes=before)
                summary["observations"].append(record)
                record["unchanged"] = hashes(directory) == before
                record["codes"] = sorted(int(code) for code in re.findall(r"error TS(\d+):", record["stdout"]))
                record["diagnostic_headers"] = [line.replace(str(directory) + "/", "")
                    for line in record["stdout"].splitlines() if re.search(r"error TS\d+:", line)]
                record["ordered_graph"] = listed_paths(record["stdout"], directory)
                record["graph"] = sorted(record["ordered_graph"])
                summary.pop("pending", None)
                checkpoint()
                assert record["unchanged"] and not record["stderr"], record
                assert record["codes"] == sorted(case["codes"]), record
                assert record["exit"] == (1 if case["codes"] else 0), record
                project_graph = [name for name in record["graph"] if not Path(name).is_absolute()]
                expected_graph = case["expected_graph"] if case["expected_graph"] is not None else [name for name in files if name != "tsconfig.json"]
                assert project_graph == sorted(expected_graph), record
                assert len(record["ordered_graph"]) == len(set(record["ordered_graph"])), record
                if not case["libraries"]:
                    assert record["graph"] == project_graph, record
                paired.append(record)
                if case["controls"] or case["semantic"]:
                    summary["pending"] = dict(case=case["name"], engine=engine, mode="semantic-control")
                    checkpoint()
                    control = invoke([str(executable), "-p", "tsconfig.json", "--pretty", "false", "--noEmit", "--listFiles", *case["flags"]], directory)
                    control.update(case=case["name"], engine=engine, mode="semantic-control",
                                   ordered_graph=listed_paths(control["stdout"], directory))
                    summary["observations"].append(control)
                    summary.pop("pending", None)
                    checkpoint()
                    assert control["exit"] == int(bool(case["controls"])) and not control["stderr"], control
                    assert sorted(int(code) for code in re.findall(r"error TS(\d+):", control["stdout"])) == sorted(case["controls"]), control
                    assert hashes(directory) == before, control
                    assert control["ordered_graph"] == record["ordered_graph"], control
            if len(paired) == 2:
                for key in ("input_hashes", "exit", "codes", "diagnostic_headers", "graph", "ordered_graph"):
                    assert paired[0][key] == paired[1][key], (key, paired)
        assert all(hashlib.sha256(Path(path).read_bytes()).hexdigest() == digest
                   for path, digest in library_inputs.items())
        summary["passed"] = True
        print(f"List-files contracts passed: {len(cases())} cases, {len(summary['observations'])} observations")
    finally:
        checkpoint()


if __name__ == "__main__":
    main()
