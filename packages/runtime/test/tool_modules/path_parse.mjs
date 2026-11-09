import path, { parse } from 'node:path';
import alias from 'path';
import posix from 'node:path/posix';
import posixAlias from 'path/posix';
function check(value, message) { if (!value) throw new Error(message); }
check(typeof parse === 'function' && parse === path.parse && path === alias && path.posix === posix && posixAlias === posix, 'parse aliases');
// Node 26.10 POSIX oracle vectors.
const cases = [
  ["", {"root": "", "dir": "", "base": "", "ext": "", "name": ""}],
  ["/", {"root": "/", "dir": "/", "base": "", "ext": "", "name": ""}],
  ["//", {"root": "/", "dir": "/", "base": "", "ext": "", "name": ""}],
  ["///", {"root": "/", "dir": "/", "base": "", "ext": "", "name": ""}],
  ["////", {"root": "/", "dir": "/", "base": "", "ext": "", "name": ""}],
  ["a", {"root": "", "dir": "", "base": "a", "ext": "", "name": "a"}],
  ["a/", {"root": "", "dir": "", "base": "a", "ext": "", "name": "a"}],
  ["a//", {"root": "", "dir": "", "base": "a", "ext": "", "name": "a"}],
  ["./", {"root": "", "dir": "", "base": ".", "ext": "", "name": "."}],
  ["../", {"root": "", "dir": "", "base": "..", "ext": "", "name": ".."}],
  [".", {"root": "", "dir": "", "base": ".", "ext": "", "name": "."}],
  ["..", {"root": "", "dir": "", "base": "..", "ext": "", "name": ".."}],
  ["...", {"root": "", "dir": "", "base": "...", "ext": ".", "name": ".."}],
  ["....", {"root": "", "dir": "", "base": "....", "ext": ".", "name": "..."}],
  [".a", {"root": "", "dir": "", "base": ".a", "ext": "", "name": ".a"}],
  [".a.", {"root": "", "dir": "", "base": ".a.", "ext": ".", "name": ".a"}],
  [".a..", {"root": "", "dir": "", "base": ".a..", "ext": ".", "name": ".a."}],
  ["a.", {"root": "", "dir": "", "base": "a.", "ext": ".", "name": "a"}],
  ["a..", {"root": "", "dir": "", "base": "a..", "ext": ".", "name": "a."}],
  ["a.b", {"root": "", "dir": "", "base": "a.b", "ext": ".b", "name": "a"}],
  ["a.b.c", {"root": "", "dir": "", "base": "a.b.c", "ext": ".c", "name": "a.b"}],
  ["/.a", {"root": "/", "dir": "/", "base": ".a", "ext": "", "name": ".a"}],
  ["/.a/", {"root": "/", "dir": "/", "base": ".a", "ext": "", "name": ".a"}],
  ["/..", {"root": "/", "dir": "/", "base": "..", "ext": ".", "name": "."}],
  ["/...", {"root": "/", "dir": "/", "base": "...", "ext": ".", "name": ".."}],
  ["//a", {"root": "/", "dir": "/", "base": "a", "ext": "", "name": "a"}],
  ["///a", {"root": "/", "dir": "//", "base": "a", "ext": "", "name": "a"}],
  ["///a///", {"root": "/", "dir": "//", "base": "a", "ext": "", "name": "a"}],
  ["a/b", {"root": "", "dir": "a", "base": "b", "ext": "", "name": "b"}],
  ["a//b", {"root": "", "dir": "a/", "base": "b", "ext": "", "name": "b"}],
  ["a///b///", {"root": "", "dir": "a//", "base": "b", "ext": "", "name": "b"}],
  ["a/../b.txt", {"root": "", "dir": "a/..", "base": "b.txt", "ext": ".txt", "name": "b"}],
  ["a/./.hidden", {"root": "", "dir": "a/.", "base": ".hidden", "ext": "", "name": ".hidden"}],
  ["a//.b/", {"root": "", "dir": "a/", "base": ".b", "ext": "", "name": ".b"}],
  ["a\\b.txt", {"root": "", "dir": "", "base": "a\\b.txt", "ext": ".txt", "name": "a\\b"}],
  ["C:\\foo\\bar.txt", {"root": "", "dir": "", "base": "C:\\foo\\bar.txt", "ext": ".txt", "name": "C:\\foo\\bar"}],
  ["file:///tmp/a.txt", {"root": "", "dir": "file:///tmp", "base": "a.txt", "ext": ".txt", "name": "a"}],
  [" spaced/.env", {"root": "", "dir": " spaced", "base": ".env", "ext": "", "name": ".env"}],
  ["\ud83d\udfe2/\u00e9.txt", {"root": "", "dir": "\ud83d\udfe2", "base": "\u00e9.txt", "ext": ".txt", "name": "\u00e9"}],
  ["a\u0000b.txt", {"root": "", "dir": "", "base": "a\u0000b.txt", "ext": ".txt", "name": "a\u0000b"}],
  ["a/\ud800.x", {"root": "", "dir": "a", "base": "\ud800.x", "ext": ".x", "name": "\ud800"}],
  ["a/\ud83d\ude00.z", {"root": "", "dir": "a", "base": "\ud83d\ude00.z", "ext": ".z", "name": "\ud83d\ude00"}],
];
for (const [input, expected] of cases) { const actual = parse(input); check(JSON.stringify(actual) === JSON.stringify(expected), 'parse result: ' + JSON.stringify(input)); check(Object.getPrototypeOf(actual) === Object.prototype && Object.keys(actual).join(',') === 'root,dir,base,ext,name', 'ordinary result object'); for (const key of Object.keys(actual)) { const descriptor = Object.getOwnPropertyDescriptor(actual,key); check(descriptor.writable && descriptor.configurable && descriptor.enumerable, 'result descriptor'); } }
for (const invalid of [undefined,null,1,true,0n,Symbol('path'),{},[],new String('a')]) { let error; try { parse(invalid); } catch (caught) { error=caught; } check(error instanceof TypeError && error.code === 'ERR_INVALID_ARG_TYPE', 'reject non-string input'); }
const first=parse('a.txt'),second=parse('a.txt');check(first!==second,'fresh result');first.name='changed';check(second.name==='a','independent results');
for (const code of [0xd800, 0xdc00]) { const unit = String.fromCharCode(code); const result = parse('a/' + unit + '.x'); check(result.name.charCodeAt(0) === code && result.name.length === 1 && result.ext === '.x', 'preserve UTF16 code units'); }
console.log('OK POSIX path.parse lexical roots, directories, extensions, unicode and validation');
