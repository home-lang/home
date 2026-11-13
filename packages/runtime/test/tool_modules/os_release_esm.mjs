import os, {release} from 'node:os';
import {createRequire} from 'node:module';
const require = createRequire(import.meta.url);
console.log(JSON.stringify({same: os.release === release && require('os') === os, release: release(), primitive: String(release)}));
