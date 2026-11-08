#!/usr/bin/env python3
"""Compare complete inclusion reasons through the actual native CLIs.

Run under scripts/run-bounded.pl. Fixtures stay in the exclusive output
directory. These checks complement the separate filename/casing matrix.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path, required=True)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    globals_source = "\n".join(f"interface {name} {{}}" for name in (
        "Array<T>", "Boolean", "CallableFunction", "Function", "IArguments",
        "NewableFunction", "Number", "Object", "RegExp", "String", "Promise<T>",
    )) + ("\ninterface PromiseConstructor { new<T>(executor: (resolve: (value: T) => void, reject: (reason?: any) => void) => void): Promise<T>; }\n"
          "declare var Promise: PromiseConstructor;\ndeclare function require(name: string): any;\n")
    imported_a = 'import { shared } from "./shared"; export const a = shared;\n'
    imported_b = 'import { shared } from "./shared"; export const b = shared;\n'
    cases = [
        ("two-importers", ["a.ts", "b.ts"], {"a.ts": imported_a, "b.ts": imported_b}, [
            'Imported via "./shared" from file \'a.ts\'',
            'Imported via "./shared" from file \'b.ts\'',
        ]),
        ("two-import-sites", ["a.ts"], {"a.ts": (
            'import { shared as one } from "./shared";\n'
            'import { shared as two } from "././shared";\n'
            'export const total = one + two;\n'
        )}, [
            'Imported via "./shared" from file \'a.ts\'',
            'Imported via "././shared" from file \'a.ts\'',
        ]),
        ("identical-import-sites", ["a.ts"], {"a.ts": (
            'import { shared as one } from "./shared";\n'
            'import { shared as two } from "./shared";\n'
            'export const total = one + two;\n'
        )}, [
            'Imported via "./shared" from file \'a.ts\'',
            'Imported via "./shared" from file \'a.ts\'',
        ]),
        ("authored-import-quotes", ["a.ts"], {"a.ts": (
            "import { shared as one } from './shared';\n"
            'import { shared as two } from "./sh\\u0061red";\n'
            'export const total = one + two;\n'
        )}, [
            "Imported via './shared' from file 'a.ts'",
            'Imported via "./sh\\u0061red" from file \'a.ts\'',
        ]),
        ("identical-re-export-sites", ["a.ts"], {"a.ts": (
            "export { shared as one } from './shared';\n"
            "export { shared as two } from './shared';\n"
        )}, [
            "Imported via './shared' from file 'a.ts'",
            "Imported via './shared' from file 'a.ts'",
        ]),
        ("escaped-re-export-emission", ["a.ts"], {"a.ts": (
            'export { shared } from "./sh\\u0061red";\n'
        )}, [
            'Imported via "./sh\\u0061red" from file \'a.ts\'',
        ]),
        ("escaped-require-sites", ["a.js"], {"a.js": (
            'export const one = require("./sh\\u0061red");\n'
            'export const two = require(`./sh\\u0061red`);\n'
        )}, [
            'Imported via "./sh\\u0061red" from file \'a.js\'',
            "Imported via `./sh\\u0061red` from file 'a.js'",
        ]),
        ("escaped-dynamic-import-sites", ["a.ts"], {"a.ts": (
            'export const one = import("./sh\\u0061red");\n'
            'export const two = import(`./sh\\u0061red`);\n'
        )}, [
            'Imported via "./sh\\u0061red" from file \'a.ts\'',
            "Imported via `./sh\\u0061red` from file 'a.ts'",
        ]),
        ("escaped-ambient-identity", ["shared.ts", "a.ts"], {
            "shared.ts": 'declare module "kit\\u002dname" { export const shared: number; }\n',
            "a.ts": 'import { shared } from "kit-name"; export const a = shared;\n',
        }, ["Part of 'files' list in tsconfig.json"]),
        ("escaped-ambient-and-import-identity", ["shared.ts", "a.ts"], {
            "shared.ts": 'declare module "kit\\u002dname" { export const shared: number; }\n',
            "a.ts": 'import { shared } from "kit\\u002dname"; export const a = shared;\n',
        }, ["Part of 'files' list in tsconfig.json"]),
        ("two-references", ["a.ts", "b.ts"], {
            "a.ts": '/// <reference path="./shared.ts" />\nexport const a = 1;\n',
            "b.ts": '/// <reference path="./shared.ts" />\nexport const b = 2;\n',
        }, [
            "Referenced via './shared.ts' from file 'a.ts'",
            "Referenced via './shared.ts' from file 'b.ts'",
        ]),
        ("mixed-reference-and-import", ["a.ts"], {"a.ts": (
            '/// <reference path="./shared.ts" />\n'
            'import { shared } from "./shared"; export const a = shared;\n'
        )}, [
            "Referenced via './shared.ts' from file 'a.ts'",
            'Imported via "./shared" from file \'a.ts\'',
        ]),
        ("root-and-import", ["a.ts", "shared.ts"], {"a.ts": imported_a}, [
            'Imported via "./shared" from file \'a.ts\'',
            "Part of 'files' list in tsconfig.json",
        ]),
    ]
    binaries = [("reference", args.reference.resolve()), ("home", args.home.resolve())]
    sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
    report = {
        "scope": "All actual import/reference reasons for one file, including root overlap and distinct sites. Not full casing or platform/SDK qualification.",
        "binaries": {name: sha(path) for name, path in binaries},
        "observations": [], "comparisons": [], "passed": False,
    }
    try:
        for name, files, sources, expected in cases:
            rows = []
            for engine, executable in binaries:
                directory = root / name / engine
                directory.mkdir(parents=True)
                (directory / "globals.d.ts").write_text(globals_source)
                (directory / "shared.ts").write_text("export const shared: number = 1;\n")
                for filename, source in sources.items():
                    (directory / filename).write_text(source)
                emit = name == "escaped-re-export-emission"
                options = {"noLib": True, "noEmit": not emit, "target": "ESNext", "module": "ESNext"}
                if any(path.endswith(".js") for path in files):
                    options.update(allowJs=True, checkJs=True)
                if emit:
                    options.update(declaration=True, outDir="dist")
                (directory / "tsconfig.json").write_text(json.dumps({
                    "files": ["globals.d.ts", *files],
                    "compilerOptions": options,
                }) + "\n")
                original = {str(path.relative_to(directory)): sha(path) for path in directory.rglob("*") if path.is_file()}
                command = [str(executable), "-p", "tsconfig.json", "--pretty", "false", "--explainFiles"]
                result = subprocess.run(command, cwd=directory, capture_output=True, text=True, timeout=30)
                reasons = []
                in_shared = False
                for line in result.stdout.splitlines():
                    if line and not line[0].isspace():
                        in_shared = line == "shared.ts" or line.replace("\\", "/").endswith("/shared.ts")
                    elif in_shared and line.strip():
                        reasons.append(line.strip().replace(str(directory) + "/", ""))
                unchanged = all(sha(directory / path) == value for path, value in original.items())
                assert unchanged, directory
                emitted = {str(path.relative_to(directory / "dist")): path.read_text()
                           for path in sorted((directory / "dist").rglob("*")) if path.is_file()}
                emission_valid = (set(emitted) == {"a.js", "a.d.ts", "shared.js", "shared.d.ts"}
                                  and all("./sh\\u0061red" in emitted.get(path, "") for path in ("a.js", "a.d.ts"))) if emit else not emitted
                row = dict(case=name, engine=engine, command=command, cwd=str(directory),
                           exit=result.returncode, stdout=result.stdout, stderr=result.stderr,
                           codes=re.findall(r"error TS(\d+):", result.stdout), reasons=reasons,
                           inputHashes=original, inputsUnchanged=unchanged,
                           emitted=emitted, emissionValid=emission_valid)
                report["observations"].append(row)
                rows.append(row)
            reference, home = rows
            assert reference["exit"] == 0 and reference["stderr"] == "" and reference["codes"] == [], reference
            assert reference["reasons"] == expected, reference
            assert reference["emissionValid"], reference
            parity = home["exit"] == 0 and home["stderr"] == "" and home["codes"] == [] and home["reasons"] == expected and home["emissionValid"]
            report["comparisons"].append(dict(case=name, parity=parity))
        assert report["binaries"] == {name: sha(path) for name, path in binaries}
        report["passed"] = all(row["parity"] for row in report["comparisons"])
    finally:
        (root / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps({"passed": report["passed"], "comparisons": report["comparisons"]}))
    raise SystemExit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
