import path, { relative } from 'node:path';
import alias from 'path';
import posix from 'node:path/posix';
import posixAlias from 'path/posix';
function check(value, message) { if (!value) throw new Error(message); }
check(typeof relative === 'function' && relative === path.relative && path === alias && path.posix === posix && posixAlias === posix, 'relative aliases');
// Node 26.10 POSIX oracle vectors.
const cases = [
  ["", "", ""],
  ["", "a", "a"],
  ["a", "", ".."],
  ["a", "b", "../b"],
  ["./a", "a/", ""],
  ["a/b", "a/c", "../c"],
  ["a/../b", "b/c", "c"],
  ["a//b/../c", "a/d", "../d"],
  ["/", "/a", "a"],
  ["/a", "/", ".."],
  ["/a/b", "/a/c", "../c"],
  ["/a", "/ab", "../ab"],
  ["/ab", "/a", "../a"],
  ["/A", "/a", "../a"],
  ["/a//b/../c", "/a/d", "../d"],
  ["/a/../../b", "/b/c", "c"],
  ["/a", "//a/", ""],
  ["//a", "///a", ""],
  ["/a", "/a/.", ""],
  ["/a", "/a/b/..", ""],
  ["/a\\b", "/a/b", "../a/b"],
  ["C:\\a", "C:\\b", "../C:\\b"],
  ["/\u00e9", "/e\u0301", "../e\u0301"],
  ["/\ud83d\udfe2/a", "/\ud83d\udfe2/b", "../b"],
  ["/a/\u0000x", "/a/\u0000y", "../\u0000y"],
  ["/a/\ud800", "/a/x", "../x"],
  ["/a/x", "/a/\ud800", "../\ud800"],
  ["/a/\udc00", "/a/\ud800", "../\ud800"],

];
for (const [from,to,expected] of cases) check(relative(from,to) === expected, 'relative result: ' + JSON.stringify([from,to]));
const cwd = process.cwd();
check(relative(cwd,'child') === 'child' && relative('child',cwd) === '..' && relative(cwd,'.') === '', 'cwd resolution');
for (const value of [undefined,null,1,true,0n,Symbol('path'),{},[],new String('a')]) {
  for (const args of [[value,'/a'],['/a',value],[value,value]]) {
    let error;
    try { relative(...args); } catch(caught) { error=caught; }
    check(error instanceof TypeError && error.code === 'ERR_INVALID_ARG_TYPE', 'validate both inputs before equality');
  }
}
const originalCwd=process.cwd;
let cwdCalls=0;
process.cwd=function(){cwdCalls++;throw new Error('unexpected cwd');};
try { check(relative('/a','/b') === '../b' && relative('same','same') === '' && cwdCalls === 0, 'absolute and identical paths avoid cwd'); }
finally { process.cwd=originalCwd; }
for(const code of [0xd800,0xdc00]) {
  const unit=String.fromCharCode(code);
  const result=relative('/a','/a/'+unit);
  check(result.length===1 && result.charCodeAt(0)===code,'preserve UTF16');
}
console.log('OK POSIX path.relative, segment boundaries, cwd, roots, unicode and validation');
