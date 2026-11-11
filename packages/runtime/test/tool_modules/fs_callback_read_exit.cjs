const fs = require('node:fs');
const [mode, path, marker] = process.argv.slice(2);
const callback = function() {
  fs.appendFileSync(marker, 'X');
  if (mode === 'live') console.log('FS CALLBACK LIVE REAL BYTES', arguments[1].length);
  else throw new Error('FS_CALLBACK_FATAL_WITNESS');
};
if (mode === 'directory') fs.readdir(path, callback);
else fs.readFile(path, callback);
