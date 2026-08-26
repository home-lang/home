#!/usr/bin/env python3
"""Reproducible frontend benchmarks for tsc, tsgo, and home-tsc."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import platform
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:  # Python 3.10 and older
    tomllib = None

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
CORPUS = HERE / "corpus"
TOOLS = HERE / ".tools"
RESULTS = HERE / "results"
MANIFEST = HERE / "corpus.toml"


def run(command: list[str], *, cwd: Path | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    print("+", " ".join(command), flush=True)
    return subprocess.run(command, cwd=cwd, check=check, text=True)


def manifest() -> dict:
    if tomllib is not None:
        with MANIFEST.open("rb") as handle:
            return tomllib.load(handle)

    # The benchmark manifest intentionally uses only tables and scalar values,
    # so older system Pythons do not need a third-party TOML dependency.
    result: dict = {}
    current = result
    for raw_line in MANIFEST.read_text(encoding="utf-8").splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            current = result
            for part in line[1:-1].split("."):
                current = current.setdefault(part, {})
            continue
        key, raw_value = (part.strip() for part in line.split("=", 1))
        if raw_value.startswith('"'):
            current[key] = json.loads(raw_value)
        else:
            current[key] = int(raw_value)
    return result


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def shared_config(*, jsx: bool = False) -> str:
    compiler_options: dict[str, object] = {
        "strict": True,
        "noEmit": True,
        "noLib": True,
        "skipLibCheck": True,
        "pretty": False,
    }
    if jsx:
        compiler_options["jsx"] = "preserve"
    include = ["src/**/*.ts", "src/**/*.tsx"] if jsx else ["src/**/*.ts"]
    return json.dumps(
        {
            "compilerOptions": compiler_options,
            "include": include,
        },
        indent=2,
    ) + "\n"


def generate_minimal_lib(directory: Path) -> None:
    write(
        directory / "src/lib.d.ts",
        "interface Object {}\n"
        "interface Function {}\n"
        "interface CallableFunction extends Function {}\n"
        "interface NewableFunction extends Function {}\n"
        "interface IArguments { readonly length: number; [index: number]: unknown; }\n"
        "interface String {}\n"
        "interface Number {}\n"
        "interface Boolean {}\n"
        "interface RegExp {}\n"
        "interface Array<T> { readonly length: number; [index: number]: T; }\n"
        "interface ReadonlyArray<T> { readonly length: number; readonly [index: number]: T; }\n",
    )


def generate_startup(directory: Path) -> None:
    write(directory / "tsconfig.json", shared_config())
    generate_minimal_lib(directory)
    write(
        directory / "src/index.ts",
        "type Pair<T> = readonly [T, T];\n"
        "const pair: Pair<number> = [1, 2];\n"
        "export const total: number = pair[0] + pair[1];\n",
    )


def many_file_source(index: int) -> str:
    return f"""export interface Entity{index}<T> {{
  readonly id: number;
  readonly value: T;
  map<U>(fn: (value: T) => U): Entity{index}<U>;
}}

export type Result{index}<T, E = string> =
  | {{ readonly ok: true; readonly value: T }}
  | {{ readonly ok: false; readonly error: E }};

export type Unwrap{index}<T> = T extends Result{index}<infer U, unknown> ? U : never;

export function transform{index}<T, U>(
  input: Entity{index}<T>,
  fn: (value: T) => U,
): Result{index}<Entity{index}<U>> {{
  return {{ ok: true, value: input.map(fn) }};
}}

export const marker{index}: Result{index}<number> = {{ ok: true, value: {index} }};
"""


def generate_many_files(directory: Path, files: int) -> None:
    write(directory / "tsconfig.json", shared_config())
    generate_minimal_lib(directory)
    for index in range(files):
        write(directory / f"src/entity-{index:04d}.ts", many_file_source(index))


def generate_deep_types(directory: Path, repetitions: int) -> None:
    write(directory / "tsconfig.json", shared_config())
    generate_minimal_lib(directory)
    blocks = [
        "type Primitive = string | number | boolean | bigint | symbol | null | undefined;\n",
        "type DeepReadonly<T> = T extends Primitive ? T : T extends readonly (infer U)[] ? readonly DeepReadonly<U>[] : { readonly [K in keyof T]: DeepReadonly<T[K]> };\n",
        "type Paths<T> = T extends object ? { [K in keyof T & string]: K | `${K}.${Paths<T[K]> & string}` }[keyof T & string] : never;\n",
    ]
    for index in range(repetitions):
        blocks.append(
            f"interface Model{index}<T> {{ id: number; payload: T; nested: {{ left: T; right: readonly T[] }}; }}\n"
            f"type ReadonlyModel{index} = DeepReadonly<Model{index}<{{ name: string; score: number }}>>;\n"
            f"type ModelPaths{index} = Paths<Model{index}<{{ name: string; score: number }}>>;\n"
            f"const path{index}: ModelPaths{index} = \"nested.left.name\";\n"
        )
    write(directory / "src/deep-types.ts", "".join(blocks))


def import_graph_source(index: int) -> str:
    if index == 0:
        return """export interface Model0<T> {
  readonly current: T;
}

export function make0<T>(value: T): Model0<T> {
  return { current: value };
}

export const marker0: Model0<number> = make0(0);
"""

    previous = index - 1
    return f"""import {{ Model{previous}, make{previous} }} from "./module-{previous:04d}";

export interface Model{index}<T> {{
  readonly current: T;
  readonly previous: Model{previous}<T>;
}}

export function make{index}<T>(value: T): Model{index}<T> {{
  return {{ current: value, previous: make{previous}(value) }};
}}

export const marker{index}: Model{index}<number> = make{index}({index});
"""


def generate_import_graph(directory: Path, modules: int) -> None:
    write(directory / "tsconfig.json", shared_config())
    generate_minimal_lib(directory)
    for index in range(modules):
        write(directory / f"src/module-{index:04d}.ts", import_graph_source(index))
    last = modules - 1
    write(
        directory / "src/index.ts",
        f'import {{ Model{last}, make{last} }} from "./module-{last:04d}";\n'
        f"export const result: Model{last}<string> = make{last}(\"home\");\n",
    )


def reexport_leaf_source(index: int) -> str:
    return f"""export interface Item{index}<T> {{
  readonly id: number;
  readonly value: T;
}}

export function create{index}<T>(value: T): Item{index}<T> {{
  return {{ id: {index}, value }};
}}
"""


def generate_reexport_graph(directory: Path, leaves: int, barrel_size: int) -> None:
    if leaves % barrel_size != 0:
        raise ValueError("reexport graph leaves must be divisible by barrel size")
    write(directory / "tsconfig.json", shared_config())
    generate_minimal_lib(directory)
    for index in range(leaves):
        write(directory / f"src/leaf-{index:04d}.ts", reexport_leaf_source(index))

    index_lines: list[str] = []
    barrel_count = leaves // barrel_size
    for barrel in range(barrel_count):
        first = barrel * barrel_size
        exports = [
            f'export * from "./leaf-{leaf:04d}";\n'
            for leaf in range(first, first + barrel_size)
        ]
        write(directory / f"src/barrel-{barrel:02d}.ts", "".join(exports))
        index_lines.append(
            f'import {{ Item{first}, create{first} }} from "./barrel-{barrel:02d}";\n'
            f"const value{barrel}: Item{first}<number> = create{first}({first});\n"
        )
    values = ", ".join(f"value{barrel}.value" for barrel in range(barrel_count))
    index_lines.append(f"export const values = [{values}] as const;\n")
    write(directory / "src/index.ts", "".join(index_lines))


def generate_tsx_components(directory: Path, components: int) -> None:
    write(directory / "tsconfig.json", shared_config(jsx=True))
    generate_minimal_lib(directory)
    blocks = [
        "declare global {\n"
        "  namespace JSX {\n"
        "    interface Element { readonly kind: string; }\n"
        "    interface IntrinsicElements {\n"
        "      article: { readonly id?: string; readonly children?: unknown };\n"
        "      h2: { readonly children?: unknown };\n"
        "      span: { readonly children?: unknown };\n"
        "    }\n"
        "  }\n"
        "}\n\n"
        "interface CardProps<T> {\n"
        "  readonly label: string;\n"
        "  readonly value: T;\n"
        "  readonly active: boolean;\n"
        "}\n\n"
    ]
    for index in range(components):
        blocks.append(
            f"export function Card{index}(props: CardProps<number>): JSX.Element {{\n"
            "  return (\n"
            f'    <article id="card-{index}">\n'
            "      <h2>{props.label}</h2>\n"
            "      <span>{props.active ? props.value : 0}</span>\n"
            "    </article>\n"
            "  );\n"
            "}\n\n"
            f'export const card{index}: JSX.Element = <Card{index} label="Card {index}" value={{{index}}} active={{{index} % 2 == 0}} />;\n\n'
        )
    write(directory / "src/components.tsx", "".join(blocks))


def generate_generic_calls(directory: Path, calls: int) -> None:
    write(directory / "tsconfig.json", shared_config())
    generate_minimal_lib(directory)
    blocks = [
        "interface Entity<N extends number> {\n"
        "  readonly id: N;\n"
        "  readonly label: `entity-${N}`;\n"
        "  readonly active: boolean;\n"
        "}\n\n"
        "type PickFields<T, K extends keyof T> = { readonly [P in K]: T[P] };\n\n"
        "declare function project<T, K extends readonly (keyof T)[]>(\n"
        "  value: T,\n"
        "  keys: K,\n"
        "): PickFields<T, K[number]>;\n\n"
        "declare function field<T, K extends keyof T>(value: T, key: K): T[K];\n\n"
        "declare function transform<T, U>(value: T, mapper: (input: T) => U): U;\n\n"
    ]
    for index in range(calls):
        active = "true" if index % 2 == 0 else "false"
        blocks.append(
            f"const entity{index}: Entity<{index}> = {{ id: {index}, label: \"entity-{index}\", active: {active} }};\n"
            f'const selected{index} = project(entity{index}, ["id", "label"] as const);\n'
            f'const label{index}: `entity-{index}` = field(selected{index}, "label");\n'
            f"export const result{index}: PickFields<Entity<{index}>, \"id\" | \"label\"> = transform(\n"
            f"  selected{index},\n"
            "  value => ({ id: value.id, label: value.label }),\n"
            ");\n\n"
        )
    write(directory / "src/generic-calls.ts", "".join(blocks))


def cmd_corpus() -> None:
    cfg = manifest()["generated"]
    shutil.rmtree(CORPUS, ignore_errors=True)
    generate_startup(CORPUS / "startup")
    generate_many_files(CORPUS / "many_files", cfg["many_files_count"])
    generate_deep_types(CORPUS / "deep_types", cfg["deep_types_repetitions"])
    generate_import_graph(CORPUS / "import_graph", cfg["import_graph_modules"])
    generate_reexport_graph(
        CORPUS / "reexport_graph",
        cfg["reexport_graph_leaves"],
        cfg["reexport_graph_barrel_size"],
    )
    generate_tsx_components(CORPUS / "tsx_components", cfg["tsx_components"])
    generate_generic_calls(CORPUS / "generic_calls", cfg["generic_calls"])
    print(f"Generated deterministic corpus in {CORPUS}")


def cmd_setup() -> None:
    versions = manifest()["compilers"]
    TOOLS.mkdir(parents=True, exist_ok=True)
    run(
        [
            "npm",
            "install",
            "--no-save",
            "--no-package-lock",
            "--prefix",
            str(TOOLS),
            f"typescript@{versions['tsc']['version']}",
            f"@typescript/native-preview@{versions['tsgo']['version']}",
        ]
    )


def compiler_commands() -> dict[str, list[str]]:
    home = Path(os.environ.get("HOME_TSC", ROOT / "zig-out/bin/home-tsc"))
    commands = {
        "tsc": [str(TOOLS / "node_modules/.bin/tsc")],
        "tsgo": [str(TOOLS / "node_modules/.bin/tsgo")],
        "home": [str(home)],
    }
    missing = [name for name, command in commands.items() if not Path(command[0]).is_file()]
    if missing:
        raise SystemExit(f"missing {', '.join(missing)}; run './run.sh setup' and build home-tsc")
    return commands


def version_output(command: list[str]) -> str:
    result = subprocess.run(command + ["--version"], check=True, capture_output=True, text=True)
    return (result.stdout or result.stderr).strip()


def validate(commands: dict[str, list[str]], workload: str) -> None:
    config = CORPUS / workload / "tsconfig.json"
    for name, command in commands.items():
        result = subprocess.run(
            command + ["--noEmit", "-p", str(config)],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0 or result.stdout or result.stderr:
            details = (result.stdout + result.stderr).strip()
            raise SystemExit(f"{name} failed validation for {workload}:\n{details}")


def cmd_cold(runs: int, warmup: int) -> Path:
    if not shutil.which("hyperfine"):
        raise SystemExit("hyperfine is required (brew install hyperfine)")
    if not CORPUS.is_dir():
        cmd_corpus()
    commands = compiler_commands()
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output = RESULTS / stamp
    output.mkdir(parents=True)
    metadata = {
        "timestamp_utc": stamp,
        "system": platform.platform(),
        "machine": platform.machine(),
        "processor": platform.processor(),
        "runs": runs,
        "warmup": warmup,
        "schedule": "round-robin interleaved",
        "compilers": {name: version_output(command) for name, command in commands.items()},
    }
    write(output / "metadata.json", json.dumps(metadata, indent=2) + "\n")
    for workload in manifest()["workloads"]:
        validate(commands, workload)
        config = CORPUS / workload / "tsconfig.json"
        benchmarks = {
            name: command + ["--noEmit", "-p", str(config)]
            for name, command in commands.items()
        }
        names = list(benchmarks)

        # Warm and measure in balanced round-robin order. Running every sample
        # for compiler A before compiler B lets changing workstation load bias
        # the comparison; rotating the order makes each compiler occupy every
        # position equally while retaining Hyperfine's process timer.
        for index in range(warmup):
            order = names[index % len(names) :] + names[: index % len(names)]
            for name in order:
                subprocess.run(
                    benchmarks[name],
                    check=True,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )

        print(f"+ hyperfine interleaved {workload}: {runs} runs after {warmup} warmups", flush=True)
        for index in range(runs):
            offset = index % len(names)
            order = names[offset:] + names[:offset]
            command_line = [
                "hyperfine",
                "--shell=none",
                "--runs",
                "1",
                "--style",
                "none",
                "--export-json",
                str(output / f"{workload}-round-{index:03d}.json"),
            ]
            for name in order:
                command_line.extend(
                    [
                        "--command-name",
                        f"{name} {workload}",
                        shlex.join(benchmarks[name]),
                    ]
                )
            subprocess.run(command_line, check=True)
    print(f"Results: {output}")
    return output


def latest_results() -> Path:
    candidates = sorted(path for path in RESULTS.iterdir() if path.is_dir()) if RESULTS.is_dir() else []
    if not candidates:
        raise SystemExit("no results found; run './run.sh cold'")
    return candidates[-1]


def cmd_report(directory: Path | None) -> None:
    source = directory or latest_results()
    run([sys.executable, str(HERE / "compare.py"), str(source)])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("corpus", help="regenerate deterministic benchmark inputs")
    sub.add_parser("setup", help="install pinned tsc and tsgo locally")
    cold = sub.add_parser("cold", help="run validated cold frontend benchmarks")
    cold.add_argument("--runs", type=int, default=10)
    cold.add_argument("--warmup", type=int, default=3)
    report = sub.add_parser("report", help="render a Markdown report")
    report.add_argument("results", nargs="?", type=Path)
    sub.add_parser("all", help="generate corpus, set up tools, benchmark, and report")
    args = parser.parse_args()
    if args.command == "corpus":
        cmd_corpus()
    elif args.command == "setup":
        cmd_setup()
    elif args.command == "cold":
        cmd_cold(args.runs, args.warmup)
    elif args.command == "report":
        cmd_report(args.results)
    else:
        cmd_corpus()
        cmd_setup()
        cmd_report(cmd_cold(10, 3))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
