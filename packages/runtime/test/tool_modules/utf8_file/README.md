# UTF-8 file oracle

`pairs.bin` contains every two-byte combination, each followed by an ASCII
separator, plus valid Unicode boundary values and malformed/truncated multibyte
prefixes. `expected.json` was produced by Node's actual `Buffer.toString('utf8')`
decoder; its `node` field records the producing version. The reference also
passes on Bun 1.4.4 before and after Home's native decoder change.

Regenerate with `node packages/runtime/test/tool_modules/utf8_file/generate.mjs`.
Do not generate expectations with Home. Native allocation tests and the common
host gate compare actual decoded text against this fixed oracle; existing file
fixtures separately check initial BOM handling and EOF truncation.
