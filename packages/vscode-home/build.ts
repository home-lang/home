#!/usr/bin/env bun
import { build } from 'bun';

await build({
  entrypoints: ['./src/extension.ts'],
  outdir: './out',
  target: 'node',
  minify: true,
  external: ['vscode'],
  format: 'cjs',
});

console.log('✓ Build complete');
