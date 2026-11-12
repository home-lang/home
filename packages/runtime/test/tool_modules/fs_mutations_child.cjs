const fs = require('node:fs');
const path = require('node:path');
const [operation, mode, root] = process.argv.slice(2);
const source = path.join(root, 'child-source');
const destination = path.join(root, 'child-destination');
const marker = path.join(root, 'child-marker');
const reason = new Error('actual filesystem callback witness');
let returned = false;
let calls = 0;
if (mode === 'handled' || mode === 'error') {
  process.on('unhandledRejection', () => process.exit(93));
  process.on('uncaughtException', (error, origin) => {
    if (error !== reason || origin !== 'uncaughtException' || calls !== 1) process.exit(94);
    fs.writeFileSync(marker, 'IDENTITY');
    console.log('FS CALLBACK EXCEPTION IDENTITY ' + operation + ' ' + mode);
    process.exit(91);
  });
}
const callback = error => {
  if (!returned || ++calls !== 1) process.exit(95);
  if (mode === 'error' ? !error || error.code !== 'ENOENT' : error) process.exit(96);
  if (mode !== 'liveness') throw reason;
  fs.writeFileSync(marker, 'LIVE');
  console.log('FS CALLBACK LIVENESS ' + operation);
};
const target = mode === 'error' ? path.join(root, 'missing', 'entry') : destination;
switch (operation) {
  case 'writeFile': fs.writeFile(target, 'REAL', callback); break;
  case 'mkdir': fs.mkdir(target, callback); break;
  case 'unlink': fs.unlink(mode === 'error' ? target : source, callback); break;
  case 'copyFile': fs.copyFile(mode === 'error' ? target : source, destination, callback); break;
  default: throw new Error('Unknown operation');
}
returned = true;
