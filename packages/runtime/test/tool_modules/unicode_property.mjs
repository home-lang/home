import { createRequire } from 'node:module';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

const require = createRequire(import.meta.url);
const root = mkdtempSync(path.join(tmpdir(), 'home-unicode-property-'));
const keys = ['€','😀','£','©','×','—','a-b','a b','\u2028','\u2029','\u0301start','١first','a€','','a\u0000b','Ω','é','e\u0301','漢字','℘','a·b','a\u200cb','a\u200db','a١','𐐀','default','$','_','\ud800','\udfff'];
const contexts = [
  ['object method','const value={"€"(){return 42;}}; return value["€"]();',42],
  ['object accessors','const value={get "€"(){return this.actual;},set "€"(input){this.actual=input;}}; value["€"]=42; return value["€"];',42],
  ['class method','class Value { "€"(){return 42;} } return new Value()["€"]();',42],
  ['class fields','class Value { "€"=42; static "😀"=17; } return [new Value()["€"],Value["😀"]];',[42,17]],
  ['computed key','const value={["€"]:42}; return value["€"];',42],
  ['numeric string keys','const value={"01":1,"1e3":2,"-0":3,"9007199254740993":4}; return Object.keys(value);',['01','1e3','-0','9007199254740993']],
  ['bare Unicode identifiers','const value={Ω:42,é:17,℘:23}; return [value.Ω,value.é,value.℘];',[42,17,23]],
  ['native private field','class Value { #actual=42; read(){return this.#actual;} } return new Value().read();',42],
];
const invalid = ['const value={€:42};','const value={😀:42};','const value={\u0301first:42};','const value={Ω€:42};','const value={\\u20AC:42};','const value={Ω\\u20AC:42};'];
let checks = 0;
async function check(name, body, failures) { checks++; try {await body();} catch(error){failures.push({name,message:String(error.message)});} }
function equal(actual, expected) {if(JSON.stringify(actual)!==JSON.stringify(expected)) throw new Error(`Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);}
async function load(filename) {return filename.endsWith('.cjs') || filename.endsWith('.cts') ? require(filename) : import(filename);}
function moduleSource(body,common,typed=false) {return (typed?'const typed: number = 1;\n':'')+'const result=(function(){'+body+'})();\n'+(common?'module.exports={result};':'export {result};');}
try {
  const failures=[];
  for(let i=0;i<keys.length;i++) {
    const key=keys[i];
    await check('literal key '+i,async()=>{
      for(const extension of ['.cjs','.mjs']) {
        const filename=path.join(root,'key-'+i+extension);
        writeFileSync(filename,moduleSource('const value={'+JSON.stringify(key)+':42}; return [Object.keys(value),value['+JSON.stringify(key)+']];',extension==='.cjs'));
        equal((await load(filename)).result,[[key],42]);
      }
    },failures);
  }
  for(let i=0;i<contexts.length;i++) {
    const [name,body,expected]=contexts[i];
    await check(name,async()=>{
      for(const extension of ['.cjs','.mjs']) {
        const filename=path.join(root,'context-'+i+extension);writeFileSync(filename,moduleSource(body,extension==='.cjs'));equal((await load(filename)).result,expected);
      }
    },failures);
  }
  for(let i=0;i<invalid.length;i++) {
    await check('invalid bare key '+i,async()=>{
      for(const extension of ['.cjs','.mjs']) {
        const key='unicodeBad'+i+(extension==='.cjs'?'Cjs':'Mjs');const filename=path.join(root,'bad-'+i+extension);
        writeFileSync(filename,'globalThis.'+key+'=true;\n'+invalid[i]);let caught;try {await load(filename);} catch(error){caught=error;}
        equal(caught instanceof Error,true);equal(typeof globalThis[key],'undefined');
      }
    },failures);
  }
  console.log('UNICODE PROPERTY RESULTS '+JSON.stringify({vectors:keys.length,checks,passed:checks-failures.length,failures}));
  if(checks!==44) throw new Error('Unicode property common denominator mismatch');
  const commonFailed=failures.length;
  if(process.argv.includes('--transpile')) {
    checks=0;const profile=[];const transpiler=new Bun.Transpiler({loader:'ts'});
    function execute(source){return Function(transpiler.transformSync(source)+'\nreturn result;')();}
    for(let i=0;i<keys.length;i++) {
      const key=keys[i];await check('transformed key '+i,()=>equal(execute('const typed: number=1; const result={'+JSON.stringify(key)+':42};')[key],42),profile);
    }
    for(const [name,body,expected] of contexts) await check('transformed '+name,()=>equal(execute('const typed: number=1; const result=(function(){'+body+'})();'),expected),profile);
    await check('typed physical module formats',async()=>{
      for(const extension of ['.cts','.mts']) {
        const filename=path.join(root,'typed'+extension);writeFileSync(filename,moduleSource('const value={"€":42,"😀":17}; return [value["€"],value["😀"]];',extension==='.cts',true));equal((await load(filename)).result,[42,17]);
      }
    },profile);
    for(let i=0;i<invalid.length;i++) await check('transformed invalid key rejects at or before evaluation '+i,()=>{
      const key='unicodeTransformBad'+i;let caught;
      try {Function(transpiler.transformSync('globalThis.'+key+'=true;\n'+invalid[i]))();} catch(error){caught=error;}
      equal(caught instanceof Error,true);equal(typeof globalThis[key],'undefined');
    },profile);
    await check('transform does not execute',()=>{transpiler.transformSync('globalThis.unicodeTransformExecuted=true; const value={"€":42};');equal(typeof globalThis.unicodeTransformExecuted,'undefined');},profile);
    console.log('UNICODE PROPERTY TRANSPILE RESULTS '+JSON.stringify({checks,passed:checks-profile.length,failures:profile}));
    if(checks!==46 || profile.length) throw new Error('Unicode property typed/transform mismatch');
  }
  if(commonFailed) throw new Error('Unicode property common checks failed');
  console.log('UNICODE PROPERTY 44 EXECUTED CHECKS OK');
}
finally {rmSync(root,{recursive:true,force:true});}
