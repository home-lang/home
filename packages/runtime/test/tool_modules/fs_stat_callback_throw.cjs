const fs = require('node:fs');
process.on('uncaughtException', function(error) {
  if (error.message !== 'native stat callback witness') throw error;
  console.log('OK native stat callback exception dispatch');
});
fs.stat('.', function(error, info) {
  if (error) throw error;
  if (!info.isDirectory()) throw new Error('stat did not read actual directory');
  throw new Error('native stat callback witness');
});
