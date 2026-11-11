import win32 from 'node:path/win32';
import legacy from 'path/win32';
import path from 'node:path';
import posix from 'node:path/posix';
import fs from 'node:fs';
const failures=[],passed=[];
function group(name,fn){try{if(!fn())throw new Error('predicate failed');passed.push(name);}catch(e){failures.push({name,error:String(e)});}}
function invalid(fn,arg){try{fn(arg);return false;}catch(e){return e instanceof TypeError&&e.code==='ERR_INVALID_ARG_TYPE';}}
group('aliases-and-flavor-identities',()=>win32===legacy&&path.win32===win32&&win32.win32===win32&&win32.posix===posix&&posix.win32===win32);
group('lexical-flavors-differ',()=>win32.sep==='\\'&&win32.delimiter===';'&&win32.normalize('a\\b\\..')==='a'&&posix.normalize('a\\b\\..')==='a\\b\\..');
group('drive-relative-and-root-boundaries',()=>win32.normalize('C:foo/../bar')==='C:bar'&&win32.normalize('C:/../../bar')==='C:\\bar'&&win32.normalize('C:../bar')==='C:..\\bar');
group('unc-share-protected',()=>win32.normalize('//server/share/../../x')==='\\\\server\\share\\x'&&win32.normalize('//server/share')==='\\\\server\\share\\');
group('trailing-separators',()=>win32.normalize('a/../')==='.\\'&&win32.normalize('C:/a/../')==='C:\\'&&win32.normalize('a//b\\')==='a\\b\\');
group('absolute-is-lexical',()=>win32.isAbsolute('C:/a')&&win32.isAbsolute('\\a')&&win32.isAbsolute('//s/x')&&!win32.isAbsolute('C:a')&&!win32.isAbsolute('Ω:/x')&&!win32.isAbsolute(''));
group('strict-string-validation',()=>[undefined,null,true,0,{},[],new String('a'),Symbol('path')].every(v=>invalid(win32.normalize,v)&&invalid(win32.isAbsolute,v)));
group('no-coercion-side-effects',()=>{let called=false;const v={toString(){called=true;return 'C:/x';}};return invalid(win32.normalize,v)&&invalid(win32.isAbsolute,v)&&!called;});
group('detached-and-no-cwd-dependency',()=>{const normalize=win32.normalize,absolute=win32.isAbsolute,old=process.cwd;try{process.cwd=()=>{throw new Error('cwd must not be read');};return normalize('C:a/../b')==='C:b'&&absolute('C:/b')&&!absolute('C:b');}finally{process.cwd=old;}});
group('unicode-and-nul-lexical-data',()=>win32.normalize('C:/☃/é/../😀')==='C:\\☃\\😀'&&win32.normalize('a\0b/../c')==='c'&&win32.normalize('\0')==='\0');
const inputs=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const actual=inputs.map(p=>[win32.normalize(p),win32.isAbsolute(p)]);
console.log('WIN32 PATH RESULTS '+JSON.stringify({groups:passed.length+failures.length,passed:passed.length,failures}));
console.log('WIN32 PATH ACTUAL '+JSON.stringify(actual));
if(failures.length)process.exitCode=1;
