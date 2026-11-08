import processDefault, { env, argv, cwd, nextTick } from 'process';
import * as processNamespace from 'node:process';
import { createRequire } from 'node:module';
const requireHere = createRequire(import.meta.url);
if (processDefault !== globalThis.process || requireHere('process') !== processDefault || requireHere('node:process') !== processDefault || processNamespace.default !== processDefault) throw new Error('process aliases lost identity');
if (env !== processDefault.env || argv !== processDefault.argv || cwd() !== processDefault.cwd()) throw new Error('process aliases did not expose real state');
if (!argv[1].endsWith('node_process_entry.mjs') || !cwd().startsWith('/')) throw new Error('process state');
nextTick(function() { console.log('OK home-tool process module identity'); });
