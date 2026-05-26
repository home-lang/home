# Bun Generated Classes

`ZigGeneratedClasses.zig` is generated from Bun's `.classes.ts` definitions,
not handwritten in Home.

Source checkout:

- `/Users/chrisbreuer/Code/bun/src/codegen/generate-classes.ts`
- `/Users/chrisbreuer/Code/bun/src/jsc/generated_classes_list.zig`
- `/Users/chrisbreuer/Code/bun/src/**/*.classes.ts`

Generation command used for this slice:

```sh
cd /Users/chrisbreuer/Code/bun
ONLY_ZIG=1 BUN_SILENT=1 bun src/codegen/generate-classes.ts $(find src -name '*.classes.ts' | sort) /private/tmp/home-bun-codegen
```

The resulting `/private/tmp/home-bun-codegen/ZigGeneratedClasses.zig` was copied
into this directory with trailing whitespace stripped for Home's repository
checks. Keep the generated file synchronized with the copied
`generated_classes_list.zig`; fix missing runtime symbols by porting the
corresponding Bun source, not by replacing generated methods with local shims.
