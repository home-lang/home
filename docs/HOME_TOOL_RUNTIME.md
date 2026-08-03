# Home repository-tool runtime

`home-tool` runs standalone JavaScript and TypeScript repository utilities on
Home's own TypeScript frontend and a native JavaScript engine. It does not
delegate parsing or execution to Node, Bun, or Python.

Build it with zig-js (the default when the conventional checkout and archive
exist):

```sh
zig build home-tool \
  -Dtool-js-engine=zig-js \
  -Dzig-js-root="$HOME/Code/Libraries/zig-js"
```

The checkout may instead be selected with `HOME_ZIG_JS_ROOT`. The zig-js
backend links only zig-js's public JavaScriptCore-shaped C API. Home's private
WebKit/Bun ABI remains confined to the production runtime and is not part of
the repository-tool contract.

On macOS, the system JavaScriptCore backend remains available for differential
testing:

```sh
zig build home-tool -Dtool-js-engine=jsc
```

Run TypeScript without a separate transpilation step:

```sh
zig-out/bin/home-tool run path/to/tool.ts --tool-argument
zig-out/bin/home-tool eval 'const answer: number = 40 + 2; answer' --print
```

Tools receive `console`, `process`, and a deliberately small `Home` host API:

- `Home.engine` reports `zig-js` or `jsc`.
- `Home.readTextFile`, `Home.writeTextFile`, and `Home.fileExists` provide
  synchronous repository-file access.
- `Home.spawnSync(argv)` returns `{ exitCode, stdout, stderr }`.

The runner resolves relative and absolute modules plus offline `node_modules`
packages. TypeScript/JavaScript modules emit to CommonJS, JSON modules load
directly, package `main`/`module` entries and `index.*` fallbacks are supported,
and the cache is populated before evaluation so CommonJS cycles terminate.

Use `zig build home-tool-smoke` with either engine selection to verify
TypeScript emission, module loading, filesystem access, process execution, and
argument setup.
