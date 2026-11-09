import constants, { O_RDONLY, S_IFREG } from 'node:constants';
import alias from 'constants';
import { createRequire } from 'node:module';
if (alias !== constants || O_RDONLY !== constants.O_RDONLY || S_IFREG !== constants.S_IFREG) throw new Error('constants ESM exports or aliases');
createRequire(import.meta.url)('./fs_constants.cjs');
