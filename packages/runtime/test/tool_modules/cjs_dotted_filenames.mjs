import fs from 'node:fs';
import { createRequire } from 'node:module';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
const root = fs.realpathSync(fs.mkdtempSync(join(tmpdir(), 'home-cjs-dotted-')));
const require = createRequire(join(root, 'anchor.cjs'));
let checks = 0;
function check(value, message) { checks++; if (!value) throw new Error(message); }
try {
  fs.writeFileSync(join(root, 'module.compiled.js'), 'module.exports = { value: 42 };');
  fs.writeFileSync(join(root, 'module.compiled.json'), '{"value":84}');
  fs.writeFileSync(join(root, 'config.prod.json'), '{"value":123}');
  fs.writeFileSync(join(root, 'direct.data'), 'module.exports = { value: 17 };');
  fs.writeFileSync(join(root, 'direct.data.js'), 'module.exports = { value: 34 };');
  fs.mkdirSync(join(root, 'assets.module'));
  fs.writeFileSync(join(root, 'assets.module', 'index.js'), 'module.exports = { value: 35 };');
  fs.writeFileSync(join(root, 'assets.module.js'), 'module.exports = { value: 78 };');
  fs.writeFileSync(join(root, 'invalid.compiled.js'), 'module.exports = ( ;');
  check(require('./module.compiled').value === 42, 'append .js to a real dotted basename');
  check(require.resolve('./module.compiled') === join(root, 'module.compiled.js'), 'resolve the actual suffixed file');
  check(require('./config.prod').value === 123, 'append .json to a dotted basename');
  check(require('./direct.data').value === 17, 'exact existing filename wins');
  check(require('./assets.module').value === 78, 'suffixed file wins over directory index');
  const invalid = require.resolve('./invalid.compiled');
  check(invalid === join(root, 'invalid.compiled.js') && !require.cache[invalid], 'resolve without parsing or evaluating invalid source');
  check(require('./module.compiled') === require('./module.compiled.js'), 'canonical suffix and exact filename share cache identity');
} finally { fs.rmSync(root, { recursive: true, force: true }); }
if (checks !== 7) throw new Error('Dotted filename inventory changed');
console.log('COMMONJS DOTTED FILENAMES ' + checks + ' CHECKS OK');
