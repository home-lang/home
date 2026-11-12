import { createRequire } from 'node:module';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

const require = createRequire(import.meta.url);
const root = mkdtempSync(path.join(tmpdir(), 'home-setter-default-'));
const cases = [
  ['object values and default side effects', 'let calls=0; const target={set value(input=(++calls,42)){this.actual=input;}}; target.value=undefined; const first=target.actual; target.value=null; const second=target.actual; target.value=7; return [first,second,target.actual,calls];', [42,null,7,1]],
  ['class instance and setter length', 'class Target { set value(input=11){this.actual=input;} } const target=new Target(); target.value=undefined; return [target.actual,Object.getOwnPropertyDescriptor(Target.prototype,"value").set.length];', [11,0]],
  ['static class setter', 'class Target { static set value(input=17){this.actual=input;} } Target.value=undefined; return Target.actual;', 17],
  ['computed object setter', 'const key="value"; const target={set [key](input=23){this.actual=input;}}; target[key]=undefined; return target.actual;', 23],
  ['destructuring default', 'let calls=0; const target={set value({input=(++calls,42)}={}){this.actual=input;}}; target.value=undefined; const first=target.actual; target.value={input:3}; return [first,target.actual,calls];', [42,3,1]],
  ['array binding default', 'let calls=0; const target={set value([input=(++calls,42)]=[]){this.actual=input;}}; target.value=undefined; return [target.actual,calls];', [42,1]],
  ['throwing initializer preserves identity', 'const sentinel=new Error("initializer"); let calls=0; function fail(){throw sentinel;} const target={set value(input=fail()){calls++;}}; let caught; try {target.value=undefined;} catch(error){caught=error;} return [caught===sentinel,calls];', [true,0]],
];
const invalid = [
  'const target={set value(){}};',
  'const target={set value(a,b){}};',
  'const target={set value(...items){}};',
  'const target={set value(input=1){"use strict";}};',
];
let checks = 0;
async function check(name, body, errors) {
  checks++;
  try { await body(); } catch (error) { errors.push({name,message:String(error.message)}); }
}
function equal(actual, expected) {
  if (JSON.stringify(actual)!==JSON.stringify(expected)) throw new Error(`Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}
function source(body, common, typed=false) {
  return (typed ? 'const typed: number = 1;\n' : '') + 'const result=(function(){' + body + '})();\n' + (common ? 'module.exports={result};' : 'export {result};');
}
async function load(filename) { return filename.endsWith('.cjs') || filename.endsWith('.cts') ? require(filename) : import(filename); }
try {
  const errors=[];
  for (const extension of ['.cjs','.mjs']) {
    for (let i=0;i<cases.length;i++) {
      const [name,body,expected]=cases[i];const filename=path.join(root,'case-'+i+extension);
      writeFileSync(filename,source(body,extension==='.cjs'));
      await check(extension+' '+name,async()=>equal((await load(filename)).result,expected),errors);
    }
    for (let i=0;i<invalid.length;i++) {
      const filename=path.join(root,'invalid-'+i+extension);const key='setterInvalid'+i+(extension==='.cjs'?'Cjs':'Mjs');
      writeFileSync(filename,'globalThis.'+key+'=true;\n'+invalid[i]);
      await check(extension+' invalid setter '+i,async()=>{
        let caught;try {await load(filename);} catch(error){caught=error;}
        equal(caught instanceof Error,true);equal(typeof globalThis[key],'undefined');
      },errors);
    }
  }
  console.log('SETTER DEFAULT RESULTS '+JSON.stringify({checks,passed:checks-errors.length,failures:errors}));
  if (checks!==22) throw new Error('Setter default common denominator mismatch');
  const commonFailed=errors.length;
  if (process.argv.includes('--transpile')) {
    checks=0;const profile=[];
    for (const extension of ['.cts','.mts']) {
      for (let i=0;i<cases.length;i++) {
        const [name,body,expected]=cases[i];const filename=path.join(root,'typed-'+i+extension);
        writeFileSync(filename,source(body,extension==='.cts',true));
        await check(extension+' '+name,async()=>equal((await load(filename)).result,expected),profile);
      }
    }
    const transpiler=new Bun.Transpiler({loader:'ts'});
    for (const [name,body,expected] of cases) {
      await check('transform '+name,()=>{
        const output=transpiler.transformSync(source(body,true,true));const module={exports:{}};
        Function('module',output)(module);equal(module.exports.result,expected);
      },profile);
    }
    await check('transform does not execute',()=>{
      transpiler.transformSync('globalThis.setterTransformExecuted=true; const target={set value(input=42){this.actual=input;}};');
      equal(typeof globalThis.setterTransformExecuted,'undefined');
    },profile);
    await check('transform real broken syntax rejects',()=>{
      let caught;try {transpiler.transformSync('const target={set value(input=42){this.actual=;}};');} catch(error){caught=error;}
      equal(caught instanceof Error,true);
    },profile);
    console.log('SETTER DEFAULT TRANSPILE RESULTS '+JSON.stringify({checks,passed:checks-profile.length,failures:profile}));
    if (checks!==23 || profile.length) throw new Error('Setter default typed/transform profile mismatch');
  }
  if (commonFailed) throw new Error('Setter default common checks failed');
  console.log('SETTER DEFAULT 22 EXECUTED CHECKS OK');
}
finally {rmSync(root,{recursive:true,force:true});}
