# Console assertion profile

`home-tool-console-assert-smoke` compares actual child-process stdout/stderr bytes
with the checked-in Node v26.10.0 oracle. A false `console.assert` writes a real
stderr warning and returns `undefined`, as Node does; a truthy condition stays
silent without formatting its messages. This is a console logging API, not an
assertion library or a test scheduler.

Primitive messages and `%s`, `%d`, `%i`, `%f`, `%j`, `%c`, `%%` formatting are
implemented, including missing arguments, extra primitive arguments, BigInt,
Symbol, negative zero and JSON hooks. A replaced `warn` receives the original
prefixed arguments and bound console receiver. Exceptions from warning getters
and JSON hooks propagate unchanged. Conversion functions are captured before
user code can replace globals. The method is nonconstructible and returns
`undefined` regardless of a custom warning handler's result.

Default object/function inspection and `%o`/`%O` remain explicit
`ERR_HOME_UNSUPPORTED` errors. Circular JSON formatting remains unavailable and
propagates the JSON encoder's TypeError. These refusals are tested separately;
they are not included as implemented Node-format cases. No full `util.inspect`
or `util.format` implementation is claimed.

The shared native writer reads the complete UTF-16 value, replaces unpaired
surrogates with U+FFFD, and preserves embedded NUL bytes and all following text.
This avoids the system JSC C-string conversion truncating at an invalid unit.
The same physical tests cover ordinary console `log` and `error` output.

To regenerate the oracle after an intentional Node-reference update:

```sh
python3 packages/runtime/test/tool_console_assert_fixture.py /path/to/node \
  packages/runtime/test/tool_modules/console_assert.cjs --node --generate
```

The unmodified `@napi-rs/cli` 2.18.4 `--help` entry is a separate real consumer
probe. Native addon loading, HTTP, the Bun/Node test scheduler and complete
package build/test results remain independently reported.
