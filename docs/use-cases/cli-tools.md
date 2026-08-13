# CLI Tools

Command-line tools are judged on two things: whether they start instantly and
whether they are one file to install. A native binary with no runtime gets both
for free.

## Why Home suits this

**One file to ship.** `home build` produces a native executable. Nothing to
install beside it, no interpreter version to match, no `node_modules` to
resolve at start-up.

**Start-up you can measure in microseconds.** There is no VM to warm and no
collector to initialise. For a tool invoked in a loop from a shell script, that
difference dominates everything else.

**Errors as values.** A CLI spends most of its code on things that can fail:
missing files, bad flags, malformed input. Each of them returns a `Result`, so
the failure path is written explicitly rather than caught somewhere up the
stack.

## Parsing arguments

```home
enum Command {
  Build(string),
  Check(string),
  Version,
}

fn parse_args(args: [string]) -> Result<Command, UsageError> {
  match args {
    ["build", path] => Ok(Command.Build(path)),
    ["check", path] => Ok(Command.Check(path)),
    ["--version"] | ["-v"] => Ok(Command.Version),
    _ => Err(UsageError.Unknown),
  }
}

fn main() {
  match parse_args(env.args()) {
    Ok(Command.Build(path)) => build(path),
    Ok(Command.Check(path)) => check(path),
    Ok(Command.Version) => print("1.0.0"),
    Err(e) => {
      print("usage: mytool [build|check] <path>")
      exit(1)
    },
  }
}
```

Slice patterns handle the argument shapes directly, and the compiler will not
let a new `Command` variant go unhandled. See
[pattern matching](/features/pattern-matching).

## Reading files and streaming

```home
import std::fs

fn count_lines(path: string) -> Result<int, Error> {
  let contents = fs.read_to_string(path)?
  Ok(contents.lines().count())
}
```

`?` returns early on a missing file, and the caller decides what the user
sees. See [the standard library](/reference/stdlib) for the file, process and
formatting APIs.

## Exit codes and output

Exit status is part of a tool's contract, so it is worth being deliberate
about it: a `Result` at the top of `main` maps cleanly onto zero and non-zero,
and diagnostics go to stderr while data goes to stdout.

## Home's own tools

Home's toolchain is the best worked example. `home fix`, `home symbols`,
`home explain`, `home size` and `home api-diff` are all built this way and are
described in [DX commands](/DX_COMMANDS). If you want to see how a
non-trivial CLI is structured, that is the code to read.

## Status

The interpreter runs CLI programs today. Native single-entrypoint builds work
through LLVM on arm64 and x86-64 macOS and Linux; bundling an imported module
graph into one binary is still in progress, so a multi-file tool is not yet a
single-file distribution. See the
[capability matrix](/CAPABILITY_MATRIX).

## Related

- [Getting started](/guide/getting-started)
- [DX commands](/DX_COMMANDS)
- [Pattern matching](/features/pattern-matching)
- [Standard library](/reference/stdlib)
