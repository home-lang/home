# Home Module System

## Overview

Loads and parses Home source modules, records public exports, and resolves
imports with one owned syntax tree per canonical source file.

## Features

- Bare names search the process working directory, then registered search paths,
  for a matching `.home` file.
- Relative imports (`./` and `../`) resolve from the importing module's file,
  not the process working directory. Explicit extensions are retained; otherwise
  `.home` is appended.
- Canonical file paths are the cache keys. Repeated imports and path aliases share
  a module, while equal basenames in different directories remain distinct.
- A bare request name also retains a non-owning alias after its first successful
  load, so repeating that request returns the same module even if its source
  file has since been removed. The canonical path map alone owns the module.
- Relative requests retain the same behavior per importing module: repeating
  `./sibling` from a loaded importer returns its prior module after source
  removal, without confusing an identical request from another directory.
- The loader owns parsed source, syntax trees, names, paths, and export keys until
  `deinit`. Files larger than 10 MiB and modules with parse errors are rejected.

## Usage

```zig
const modules = @import("modules");

var loader = modules.ModuleLoader.init(allocator, io);
defer loader.deinit();
try loader.addSearchPath(source_root);

const entry = try loader.loadModule("entry");
const sibling = try loader.resolveImport(entry.file_path, "./sibling");
_ = sibling;
```

`resolveImport` requires `from_module` to be the canonical `file_path` of a
module already loaded by the same loader when the import is relative. Bare-name
imports do not require an importing module. Path canonicalization uses
`std.Io.Dir.realPathFile`, whose platform support is limited; the tests below
have been exercised on macOS and do not establish Windows/Linux runtime parity.

## Testing

Run the `modules` build target, which supplies the lexer, parser, and AST
imports required by the test root. Run one guarded build at a time:

```bash
source scripts/home-bin.sh
HOME_RUN_MAX_MB=3840 run_bounded 120 pantry/.bin/zig build test -j1 -Dfilter=modules --summary all
HOME_RUN_MAX_MB=3840 run_bounded 120 zig build test -j1 -Dfilter=modules --summary all
```

## License

Part of the Home programming language project.
