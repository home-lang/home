if (process.argv[1] !== __filename) throw new Error('relative entry bypassed its main guard');
if (process.argv.slice(2).join(':') !== 'first:second') throw new Error('entry arguments changed');
console.log('OK absolute entry guard');
