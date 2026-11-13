# Repository-tool argument parsing

`home-tool-parse-args-smoke` compares real `node:util.parseArgs` observations
against a generated Node v26.10.0 oracle. The repository-tool host supports
boolean/string options, short aliases and groups, attached/separate values,
multiple values, defaults, strict/permissive handling, positionals, the `--`
terminator, boolean negation and tokens with original argument indexes.

The fixture checks result and token keys, null-prototype values, error names
and codes, input preservation, process.argv defaults and actual CommonJS/ESM
module identity. Diagnostic wording is Home's own; exact Node error text and
all observable getter/proxy ordering are not claimed by this finite oracle.
The Node reference excludes `__proto__` from values while retaining its token;
the same behavior is exercised here.

This is argument parsing, not test registration, discovery, scheduling or
execution. The upstream Bun runner's argument schema is a parser control;
none of its tests receive passing credit. Worker threads, Bun's test runner,
native addons, HTTP and other missing APIs remain separate capabilities.

Regenerate after an intentional reference update:

```sh
python3 packages/runtime/test/tool_parse_args_fixture.py /path/to/node \
  packages/runtime/test/tool_modules/util_parse_args.cjs --node --generate
```
