#!/usr/bin/env bun
import { build } from 'bun';

async function main() {
  await build({
    entrypoints: ['./src/extension.ts'],
    outdir: './out',
    target: 'node',
    minify: true,
    external: ['vscode'],
    format: 'cjs',
  });

  console.log('✓ Build complete');
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
