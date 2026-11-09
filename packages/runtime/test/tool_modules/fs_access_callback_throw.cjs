const fs = require('node:fs');
process.on('uncaughtException', function(error) {
  if (error.message !== 'native access callback witness') throw error;
  console.log('OK native access callback exception dispatch');
});
fs.access('.', function(error) {
  if (error) throw error;
  throw new Error('native access callback witness');
});
