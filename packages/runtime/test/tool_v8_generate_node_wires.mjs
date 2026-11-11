// Reference-fixture generator, never a Home execution fallback.
import { writeFileSync } from 'node:fs';
import { serialize } from 'node:v8';
import { valueCases } from './tool_modules/v8_values.mjs';
if (typeof Home !== 'undefined' || process.versions.bun || process.version !== 'v26.10.0') throw new Error('Use pinned real Node v26.10.0 to refresh this fixture');
const cases = valueCases().map(([name, value]) => ({ name, hex: serialize(value).toString('hex') }));
writeFileSync(new URL('./tool_modules/v8_node_wires.json', import.meta.url), JSON.stringify({ node: process.version, v8: process.versions.v8, wireVersion: 15, cases }, null, 2) + '\n');
