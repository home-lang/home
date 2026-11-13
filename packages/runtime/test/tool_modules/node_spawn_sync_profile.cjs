const cp = require('node:child_process');
const fs = require('node:fs');
const witness = process.argv[2];
const options = [{timeout:1},{shell:true},{killSignal:'SIGKILL'},{stdio:[0,1,2]},{stdio:'ipc'},{uid:0},{gid:0},{detached:true},{maxBuffer:32*1024*1024+1},{encoding:'hex'},{input:'x',stdio:'ignore'}];
const codes=[];
for(const option of options) {
 try { cp.spawnSync('/bin/sh',['-c','printf launched > "$1"','profile',witness],option); codes.push('executed'); }
 catch(error) { codes.push(error.code || error.name); }
}
console.log(JSON.stringify({cases:codes.length,codes,notStarted:!fs.existsSync(witness)}));
