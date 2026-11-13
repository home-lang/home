"use strict";
const cp = require('node:child_process');
const fs = require('node:fs');
const config = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (typeof cp.spawnSync !== 'function') console.log(JSON.stringify({available:false,executed:0,records:[]}));
else {
  const records = [];
  for (const test of config.cases) {
    const options = {...test.options};
    if (test.input !== undefined) {
      const buffer = Buffer.from(test.input, 'hex');
      options.input = test.inputKind === 'string' ? buffer.toString('utf8') : test.inputKind === 'view'
        ? new Uint8Array(buffer.buffer, buffer.byteOffset + 1, buffer.byteLength - 2) : test.inputKind === 'dataview'
          ? new DataView(buffer.buffer, buffer.byteOffset + 1, buffer.byteLength - 2) : buffer;
    }
    try {
      const result = test.overload ? cp.spawnSync(test.command, options) : cp.spawnSync(test.command, test.args, options);
      const record = {name:test.name,pid:result.pid,status:result.status,signal:result.signal,
        stdoutType:result.stdout === null ? 'null' : Buffer.isBuffer(result.stdout) ? 'buffer' : typeof result.stdout,
        stderrType:result.stderr === null ? 'null' : Buffer.isBuffer(result.stderr) ? 'buffer' : typeof result.stderr,
        aliases:result.output === null ? null : result.output.length === 3 && result.output[0] === null && result.output[1] === result.stdout && result.output[2] === result.stderr,
        error:result.error ? {code:result.error.code,errno:result.error.errno,syscall:result.error.syscall,path:result.error.path,spawnargs:result.error.spawnargs} : null};
      if(result.stdout != null) fs.writeFileSync(test.output + '.stdout', result.stdout);
      if(result.stderr != null) fs.writeFileSync(test.output + '.stderr', result.stderr);
      records.push(record);
    } catch(error) { records.push({name:test.name,thrown:error.code || error.name}); }
  }
  const descriptor = Object.getOwnPropertyDescriptor(cp,'spawnSync');
  console.log(JSON.stringify({available:true,executed:records.length,records,controls:{alias:require('child_process')===cp,name:cp.spawnSync.name,arity:cp.spawnSync.length,descriptor:descriptor.enumerable && descriptor.writable && descriptor.configurable}}));
}
