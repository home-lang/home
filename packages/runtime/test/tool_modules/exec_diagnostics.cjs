const cp = require('node:child_process');
const commands = {
  shell_empty: ['execSync', ['exit 7', {stdio:'pipe'}]],
  shell_stderr: ['execSync', ['printf native-cause >&2; exit 7', {stdio:'pipe'}]],
  shell_multiline: ['execSync', ['printf "first\\nsecond\\n" >&2; exit 3', {stdio:'pipe'}]],
  shell_unicode: ['execSync', ['printf "€😀" >&2; exit 4', {stdio:'pipe'}]],
  shell_binary: ['execSync', ['printf "out\\000raw\\377"; printf "err\\000raw\\376" >&2; exit 6', {stdio:'pipe'}]],
  shell_utf8: ['execSync', ['printf out; printf cause >&2; exit 5', {stdio:'pipe',encoding:'utf8'}]],
  shell_utf8_alias: ['execSync', ['printf out; printf cause >&2; exit 5', {stdio:'pipe',encoding:'utf-8'}]],
  shell_default_mirror: ['execSync', ['printf out; printf mirrored >&2; exit 2']],
  shell_false_option: ['execSync', ['printf shell-cause >&2; exit 8', {stdio:'pipe',shell:false}]],
  shell_true_option: ['execSync', ['printf shell-cause >&2; exit 8', {stdio:'pipe',shell:true}]],
  shell_explicit_option: ['execSync', ['printf shell-cause >&2; exit 8', {stdio:'pipe',shell:'/bin/sh'}]],
  shell_signal: ['execSync', ['printf signal-cause >&2; kill -TERM $$', {stdio:'pipe'}]],
  file_empty: ['execFileSync', ['/bin/sh',['-c','exit 7'],{stdio:'pipe'}]],
  file_stderr: ['execFileSync', ['/bin/sh',['-c','printf native-cause >&2; exit 7'],{stdio:'pipe'}]],
  file_empty_argument: ['execFileSync', ['/bin/sh',['-c','exit 7',''],{stdio:'pipe'}]],
  file_argument_spaces: ['execFileSync', ['/bin/sh',['-c','printf "%s" "$1" >&2; exit 7','label','actual argument'],{stdio:'pipe'}]],
  file_binary: ['execFileSync', ['/bin/sh',['-c','printf "out\\000raw\\377"; printf "err\\000raw\\376" >&2; exit 6'],{stdio:'pipe'}]],
  file_utf8: ['execFileSync', ['/bin/sh',['-c','printf out; printf cause >&2; exit 5'],{stdio:'pipe',encoding:'utf8'}]],
  file_default_mirror: ['execFileSync', ['/bin/sh',['-c','printf out; printf mirrored >&2; exit 2']]],
  file_signal: ['execFileSync', ['/bin/sh',['-c','printf signal-cause >&2; kill -TERM $$'],{stdio:'pipe'}]],
};
if (process.argv.includes('--list')) { process.stdout.write(JSON.stringify({node:process.version,cases:Object.keys(commands)})); }
else {
  const name=process.argv[process.argv.indexOf('--case')+1];
  if(!Object.hasOwn(commands,name))throw new Error('Unknown diagnostic case');
  const [method,args]=commands[name];
  let error;try{cp[method](...args);}catch(e){error=e;}
  if(!(error instanceof Error))throw new Error('Real command did not fail');
  if(error.status===0)throw new Error('Failure status was lost');
  const output=value=>value==null?null:typeof value==='string'?{kind:'string',value}:{kind:'buffer',hex:value.toString('hex')};
  const record={name,message:error.message,stringified:String(error),wrapped:String(new TypeError('Could not parse the Cargo.toml: '+error)),status:error.status,signal:error.signal,stdout:output(error.stdout),stderr:output(error.stderr),outputAliases:error.output[0]===null&&error.output[1]===error.stdout&&error.output[2]===error.stderr};
  console.log(JSON.stringify(record));
}
