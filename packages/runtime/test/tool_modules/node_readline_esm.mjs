import readline, { cursorTo, moveCursor, clearLine, clearScreenDown } from 'node:readline';
import { createRequire } from 'node:module';
const requireHere = createRequire(import.meta.url);
if (readline !== requireHere('readline')) throw new Error('ESM readline identity');
// The parent process captures actual output bytes from descriptor 1.
cursorTo(process.stdout, 0);
moveCursor(process.stdout, -1, 2);
clearLine(process.stdout, 0);
clearScreenDown(process.stdout);
