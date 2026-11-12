# Captured process failure diagnostics

`home-tool-exec-diagnostics-smoke` executes real nonzero commands and compares
captured records and physical stderr with a Node v26.10.0 oracle. It covers
`execSync` and absolute-POSIX `execFileSync`, Buffer and UTF-8 output, raw binary
bytes, signals, default stderr mirroring, explicit pipe stdio and shell options.

For a normal captured process exit or signal, `error.message` contains the
original command followed by decoded UTF-8 stderr when stderr is nonempty.
`execSync` reports the original shell command, while `execFileSync` reports the
executable and literal argument sequence. The actual status, signal, output
Buffer/string values and `error.output` aliases remain unchanged. Invalid UTF-8
is replaced in the message while original raw stderr bytes remain available.
A caller that only stringifies the error therefore receives the actual cause.

Existing absolute-executable, output/input bounds and unsupported-option
policies remain in force. This change does not extend inherited-stdio error
formatting or make native spawn/limit errors fully Node-compatible. It does not
convert failed commands into successful commands or alter process execution.

Regenerate the oracle after an intentional reference update with:

```sh
python3 packages/runtime/test/tool_exec_diagnostics_fixture.py /path/to/node \
  packages/runtime/test/tool_modules/exec_diagnostics.cjs --node --generate
```

The NAPI CLI's Cargo metadata command remains a separate consumer result. A
local Rustup installation without a default toolchain is a genuine failed
command; exposing its stderr is not a Cargo metadata/build pass or evidence of
the Linux CI failure's underlying cause. No fake Cargo executable, metadata,
Bun candidate fallback or package build/release probe is used by this fixture.
