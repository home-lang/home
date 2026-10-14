#!/usr/bin/env python3
"""Compare library array, dictionary and collation contracts with TypeScript."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

CASES = {'library-array-controls/copy-sort/ES2022': {'config': {'compilerOptions': {'lib': ['ES2022'],
                                                                            'module': 'ESNext',
                                                                            'moduleResolution': 'Bundler',
                                                                            'noEmit': True,
                                                                            'skipLibCheck': True,
                                                                            'strict': True,
                                                                            'target': 'ESNext'},
                                                        'files': ['main.ts']},
                                             'expected': [('main.ts', 2, 21, 2550),
                                                          ('main.ts', 2, 31, 7006),
                                                          ('main.ts', 2, 33, 7006)],
                                             'files': {'main.ts': 'declare const rows: '
                                                                  '{id:number}[];\n'
                                                                  'const sorted = '
                                                                  'rows.toSorted((a,b)=>a.id-b.id);\n'
                                                                  'const '
                                                                  'id:number=sorted[0].id;\n'}},
 'library-array-controls/copy-sort/ES2023': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                                            'module': 'ESNext',
                                                                            'moduleResolution': 'Bundler',
                                                                            'noEmit': True,
                                                                            'skipLibCheck': True,
                                                                            'strict': True,
                                                                            'target': 'ESNext'},
                                                        'files': ['main.ts']},
                                             'expected': [],
                                             'files': {'main.ts': 'declare const rows: '
                                                                  '{id:number}[];\n'
                                                                  'const sorted = '
                                                                  'rows.toSorted((a,b)=>a.id-b.id);\n'
                                                                  'const '
                                                                  'id:number=sorted[0].id;\n'}},
 'library-array-controls/entries/ES2022': {'config': {'compilerOptions': {'lib': ['ES2022'],
                                                                          'module': 'ESNext',
                                                                          'moduleResolution': 'Bundler',
                                                                          'noEmit': True,
                                                                          'skipLibCheck': True,
                                                                          'strict': True,
                                                                          'target': 'ESNext'},
                                                      'files': ['main.ts']},
                                           'expected': [],
                                           'files': {'main.ts': 'function rows<Row extends '
                                                                'Record<string,unknown>>(indexes:Record<string,readonly '
                                                                'Row[]>){\n'
                                                                ' for(const [name,values] of '
                                                                'Object.entries(indexes)){\n'
                                                                '  const key:string=name;\n'
                                                                '  const rows:readonly '
                                                                'Row[]=values;\n'
                                                                ' }\n'
                                                                '}\n'}},
 'library-array-controls/entries/ES2023': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                                          'module': 'ESNext',
                                                                          'moduleResolution': 'Bundler',
                                                                          'noEmit': True,
                                                                          'skipLibCheck': True,
                                                                          'strict': True,
                                                                          'target': 'ESNext'},
                                                      'files': ['main.ts']},
                                           'expected': [],
                                           'files': {'main.ts': 'function rows<Row extends '
                                                                'Record<string,unknown>>(indexes:Record<string,readonly '
                                                                'Row[]>){\n'
                                                                ' for(const [name,values] of '
                                                                'Object.entries(indexes)){\n'
                                                                '  const key:string=name;\n'
                                                                '  const rows:readonly '
                                                                'Row[]=values;\n'
                                                                ' }\n'
                                                                '}\n'}},
 'library-array-controls/locale/ES2022': {'config': {'compilerOptions': {'lib': ['ES2022'],
                                                                         'module': 'ESNext',
                                                                         'moduleResolution': 'Bundler',
                                                                         'noEmit': True,
                                                                         'skipLibCheck': True,
                                                                         'strict': True,
                                                                         'target': 'ESNext'},
                                                     'files': ['main.ts']},
                                          'expected': [],
                                          'files': {'main.ts': 'const compared:number = '
                                                               '"item2".localeCompare("item10", '
                                                               'undefined, {numeric:true});\n'}},
 'library-array-controls/locale/ES2023': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                                         'module': 'ESNext',
                                                                         'moduleResolution': 'Bundler',
                                                                         'noEmit': True,
                                                                         'skipLibCheck': True,
                                                                         'strict': True,
                                                                         'target': 'ESNext'},
                                                     'files': ['main.ts']},
                                          'expected': [],
                                          'files': {'main.ts': 'const compared:number = '
                                                               '"item2".localeCompare("item10", '
                                                               'undefined, {numeric:true});\n'}},
 'library-array-controls/predicate/ES2022': {'config': {'compilerOptions': {'lib': ['ES2022'],
                                                                            'module': 'ESNext',
                                                                            'moduleResolution': 'Bundler',
                                                                            'noEmit': True,
                                                                            'skipLibCheck': True,
                                                                            'strict': True,
                                                                            'target': 'ESNext'},
                                                        'files': ['main.ts']},
                                             'expected': [],
                                             'files': {'main.ts': 'type '
                                                                  'Scalar=string|number|boolean|null;\n'
                                                                  'type Value=Scalar|readonly '
                                                                  'Scalar[];\n'
                                                                  'function test(value:Value){\n'
                                                                  ' const '
                                                                  'candidates=Array.isArray(value)?value:[value];\n'
                                                                  ' return '
                                                                  'candidates.map(candidate=>String(candidate));\n'
                                                                  '}\n'}},
 'library-array-controls/predicate/ES2023': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                                            'module': 'ESNext',
                                                                            'moduleResolution': 'Bundler',
                                                                            'noEmit': True,
                                                                            'skipLibCheck': True,
                                                                            'strict': True,
                                                                            'target': 'ESNext'},
                                                        'files': ['main.ts']},
                                             'expected': [],
                                             'files': {'main.ts': 'type '
                                                                  'Scalar=string|number|boolean|null;\n'
                                                                  'type Value=Scalar|readonly '
                                                                  'Scalar[];\n'
                                                                  'function test(value:Value){\n'
                                                                  ' const '
                                                                  'candidates=Array.isArray(value)?value:[value];\n'
                                                                  ' return '
                                                                  'candidates.map(candidate=>String(candidate));\n'
                                                                  '}\n'}},
 'library-array-controls/readonly-copy-sort/ES2022': {'config': {'compilerOptions': {'lib': ['ES2022'],
                                                                                     'module': 'ESNext',
                                                                                     'moduleResolution': 'Bundler',
                                                                                     'noEmit': True,
                                                                                     'skipLibCheck': True,
                                                                                     'strict': True,
                                                                                     'target': 'ESNext'},
                                                                 'files': ['main.ts']},
                                                      'expected': [('main.ts', 2, 21, 2339),
                                                                   ('main.ts', 2, 31, 7006),
                                                                   ('main.ts', 2, 33, 7006)],
                                                      'files': {'main.ts': 'declare const rows: '
                                                                           'readonly '
                                                                           '{id:number}[];\n'
                                                                           'const sorted = '
                                                                           'rows.toSorted((a,b)=>a.id-b.id);\n'
                                                                           'sorted.push({id:1});\n'}},
 'library-array-controls/readonly-copy-sort/ES2023': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                                                     'module': 'ESNext',
                                                                                     'moduleResolution': 'Bundler',
                                                                                     'noEmit': True,
                                                                                     'skipLibCheck': True,
                                                                                     'strict': True,
                                                                                     'target': 'ESNext'},
                                                                 'files': ['main.ts']},
                                                      'expected': [],
                                                      'files': {'main.ts': 'declare const rows: '
                                                                           'readonly '
                                                                           '{id:number}[];\n'
                                                                           'const sorted = '
                                                                           'rows.toSorted((a,b)=>a.id-b.id);\n'
                                                                           'sorted.push({id:1});\n'}},
 'library-array-controls/union-copy-sort/ES2022': {'config': {'compilerOptions': {'lib': ['ES2022'],
                                                                                  'module': 'ESNext',
                                                                                  'moduleResolution': 'Bundler',
                                                                                  'noEmit': True,
                                                                                  'skipLibCheck': True,
                                                                                  'strict': True,
                                                                                  'target': 'ESNext'},
                                                              'files': ['main.ts']},
                                                   'expected': [('main.ts', 2, 19, 2339),
                                                                ('main.ts', 2, 29, 7006),
                                                                ('main.ts', 2, 31, 7006)],
                                                   'files': {'main.ts': 'declare const rows: '
                                                                        '{id:number}[]|{id:number;name:string}[];\n'
                                                                        'const '
                                                                        'sorted=rows.toSorted((a,b)=>a.id-b.id);\n'}},
 'library-array-controls/union-copy-sort/ES2023': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                                                  'module': 'ESNext',
                                                                                  'moduleResolution': 'Bundler',
                                                                                  'noEmit': True,
                                                                                  'skipLibCheck': True,
                                                                                  'strict': True,
                                                                                  'target': 'ESNext'},
                                                              'files': ['main.ts']},
                                                   'expected': [],
                                                   'files': {'main.ts': 'declare const rows: '
                                                                        '{id:number}[]|{id:number;name:string}[];\n'
                                                                        'const '
                                                                        'sorted=rows.toSorted((a,b)=>a.id-b.id);\n'}},
 'library-array-negative-controls/copy-sort-invalid': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                                                      'module': 'ESNext',
                                                                                      'moduleResolution': 'Bundler',
                                                                                      'noEmit': True,
                                                                                      'skipLibCheck': True,
                                                                                      'strict': True,
                                                                                      'target': 'ESNext'},
                                                                  'files': ['main.ts']},
                                                       'expected': [('main.ts', 2, 15, 2345)],
                                                       'files': {'main.ts': 'declare const '
                                                                            'rows:{id:number}[];\n'
                                                                            'rows.toSorted((a,b)=>"bad");\n'}},
 'library-array-negative-controls/copy-sort-invalid-parameter': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                                                                'module': 'ESNext',
                                                                                                'moduleResolution': 'Bundler',
                                                                                                'noEmit': True,
                                                                                                'skipLibCheck': True,
                                                                                                'strict': True,
                                                                                                'target': 'ESNext'},
                                                                            'files': ['main.ts']},
                                                                 'expected': [('main.ts',
                                                                               2,
                                                                               15,
                                                                               2345)],
                                                                 'files': {'main.ts': 'declare '
                                                                                      'const '
                                                                                      'rows:{id:number}[];\n'
                                                                                      'rows.toSorted((a:string,b:string)=>0);\n'}},
 'library-array-negative-controls/entries-alias': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                                                  'module': 'ESNext',
                                                                                  'moduleResolution': 'Bundler',
                                                                                  'noEmit': True,
                                                                                  'skipLibCheck': True,
                                                                                  'strict': True,
                                                                                  'target': 'ESNext'},
                                                              'files': ['main.ts']},
                                                   'expected': [('main.ts', 3, 54, 2322)],
                                                   'files': {'main.ts': 'type Data = {a:number};\n'
                                                                        'declare const data:Data;\n'
                                                                        'for(const [key,value] of '
                                                                        'Object.entries(data)){const '
                                                                        'wrong:boolean=value;}\n'}},
 'library-array-negative-controls/entries-array': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                                                  'module': 'ESNext',
                                                                                  'moduleResolution': 'Bundler',
                                                                                  'noEmit': True,
                                                                                  'skipLibCheck': True,
                                                                                  'strict': True,
                                                                                  'target': 'ESNext'},
                                                              'files': ['main.ts']},
                                                   'expected': [('main.ts', 1, 55, 2322)],
                                                   'files': {'main.ts': 'for(const [key,value] of '
                                                                        'Object.entries([1,2])){const '
                                                                        'wrong:boolean=value;}\n'}},
 'library-array-negative-controls/entries-class': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                                                  'module': 'ESNext',
                                                                                  'moduleResolution': 'Bundler',
                                                                                  'noEmit': True,
                                                                                  'skipLibCheck': True,
                                                                                  'strict': True,
                                                                                  'target': 'ESNext'},
                                                              'files': ['main.ts']},
                                                   'expected': [],
                                                   'files': {'main.ts': 'class Data {a=1}\n'
                                                                        'for(const [key,value] of '
                                                                        'Object.entries(new '
                                                                        'Data())){const '
                                                                        'anything:boolean=value;}\n'}},
 'library-array-negative-controls/entries-empty': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                                                  'module': 'ESNext',
                                                                                  'moduleResolution': 'Bundler',
                                                                                  'noEmit': True,
                                                                                  'skipLibCheck': True,
                                                                                  'strict': True,
                                                                                  'target': 'ESNext'},
                                                              'files': ['main.ts']},
                                                   'expected': [('main.ts', 1, 52, 2322)],
                                                   'files': {'main.ts': 'for(const [key,value] of '
                                                                        'Object.entries({})){const '
                                                                        'wrong:boolean=value;}\n'}},
 'library-array-negative-controls/entries-fallback': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                                                     'module': 'ESNext',
                                                                                     'moduleResolution': 'Bundler',
                                                                                     'noEmit': True,
                                                                                     'skipLibCheck': True,
                                                                                     'strict': True,
                                                                                     'target': 'ESNext'},
                                                                 'files': ['main.ts']},
                                                      'expected': [],
                                                      'files': {'main.ts': 'interface Data '
                                                                           '{a:number}\n'
                                                                           'declare const '
                                                                           'data:Data;\n'
                                                                           'for(const [key,value] '
                                                                           'of '
                                                                           'Object.entries(data)){ '
                                                                           'const '
                                                                           'anything:boolean=value; '
                                                                           '}\n'}},
 'library-array-negative-controls/entries-generic-import': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                                                           'module': 'ESNext',
                                                                                           'moduleResolution': 'Bundler',
                                                                                           'noEmit': True,
                                                                                           'skipLibCheck': True,
                                                                                           'strict': True,
                                                                                           'target': 'ESNext'},
                                                                       'files': ['main.ts']},
                                                            'expected': [],
                                                            'files': {'main.ts': 'import type '
                                                                                 '{Box} from '
                                                                                 '"./types";\n'
                                                                                 'declare const '
                                                                                 'box:Box<number>;\n'
                                                                                 'for(const '
                                                                                 '[key,value] of '
                                                                                 'Object.entries(box)){const '
                                                                                 'anything:boolean=value;}\n',
                                                                      'types.ts': 'export '
                                                                                  'interface '
                                                                                  'Box<T>{value:T}\n'}},
 'library-array-negative-controls/entries-generic-interface': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                                                              'module': 'ESNext',
                                                                                              'moduleResolution': 'Bundler',
                                                                                              'noEmit': True,
                                                                                              'skipLibCheck': True,
                                                                                              'strict': True,
                                                                                              'target': 'ESNext'},
                                                                          'files': ['main.ts']},
                                                               'expected': [],
                                                               'files': {'main.ts': 'interface '
                                                                                    'Box<T>{value:T}\n'
                                                                                    'declare const '
                                                                                    'box:Box<number>;\n'
                                                                                    'for(const '
                                                                                    '[key,value] '
                                                                                    'of '
                                                                                    'Object.entries(box)){const '
                                                                                    'anything:boolean=value;}\n'}},
 'library-array-negative-controls/entries-import-alias': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                                                         'module': 'ESNext',
                                                                                         'moduleResolution': 'Bundler',
                                                                                         'noEmit': True,
                                                                                         'skipLibCheck': True,
                                                                                         'strict': True,
                                                                                         'target': 'ESNext'},
                                                                     'files': ['main.ts']},
                                                          'expected': [('main.ts', 3, 54, 2322)],
                                                          'files': {'main.ts': 'import type {Data} '
                                                                               'from "./types";\n'
                                                                               'declare const '
                                                                               'data:Data;\n'
                                                                               'for(const '
                                                                               '[key,value] of '
                                                                               'Object.entries(data)){const '
                                                                               'wrong:boolean=value;}\n',
                                                                    'types.ts': 'export type '
                                                                                'Data={a:number}\n'}},
 'library-array-negative-controls/entries-import-interface': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                                                             'module': 'ESNext',
                                                                                             'moduleResolution': 'Bundler',
                                                                                             'noEmit': True,
                                                                                             'skipLibCheck': True,
                                                                                             'strict': True,
                                                                                             'target': 'ESNext'},
                                                                         'files': ['main.ts']},
                                                              'expected': [],
                                                              'files': {'main.ts': 'import type '
                                                                                   '{Data} from '
                                                                                   '"./types";\n'
                                                                                   'declare const '
                                                                                   'data:Data;\n'
                                                                                   'for(const '
                                                                                   '[key,value] of '
                                                                                   'Object.entries(data)){const '
                                                                                   'anything:boolean=value;}\n',
                                                                        'types.ts': 'export '
                                                                                    'interface '
                                                                                    'Data '
                                                                                    '{a:number}\n'}},
 'library-array-negative-controls/entries-interface-index': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                                                            'module': 'ESNext',
                                                                                            'moduleResolution': 'Bundler',
                                                                                            'noEmit': True,
                                                                                            'skipLibCheck': True,
                                                                                            'strict': True,
                                                                                            'target': 'ESNext'},
                                                                        'files': ['main.ts']},
                                                             'expected': [('main.ts', 3, 54, 2322)],
                                                             'files': {'main.ts': 'interface Data '
                                                                                  '{[key:string]:number; '
                                                                                  'a:number}\n'
                                                                                  'declare const '
                                                                                  'data:Data;\n'
                                                                                  'for(const '
                                                                                  '[key,value] of '
                                                                                  'Object.entries(data)){const '
                                                                                  'wrong:boolean=value;}\n'}},
 'library-array-negative-controls/entries-number': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                                                   'module': 'ESNext',
                                                                                   'moduleResolution': 'Bundler',
                                                                                   'noEmit': True,
                                                                                   'skipLibCheck': True,
                                                                                   'strict': True,
                                                                                   'target': 'ESNext'},
                                                               'files': ['main.ts']},
                                                    'expected': [('main.ts', 4, 8, 2322)],
                                                    'files': {'main.ts': 'declare const '
                                                                         'data:Record<string,number>;\n'
                                                                         'for(const [key,value] of '
                                                                         'Object.entries(data)){\n'
                                                                         ' const k:string=key;\n'
                                                                         ' const '
                                                                         'wrong:boolean=value;\n'
                                                                         '}\n'}},
 'library-array-negative-controls/entries-object': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                                                   'module': 'ESNext',
                                                                                   'moduleResolution': 'Bundler',
                                                                                   'noEmit': True,
                                                                                   'skipLibCheck': True,
                                                                                   'strict': True,
                                                                                   'target': 'ESNext'},
                                                               'files': ['main.ts']},
                                                    'expected': [('main.ts', 2, 7, 2322)],
                                                    'files': {'main.ts': 'const '
                                                                         'entries=Object.entries({a:1,b:"text"});\n'
                                                                         'const '
                                                                         'wrong:boolean=entries[0][1];\n'}},
 'library-array-negative-controls/entries-readonly': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                                                     'module': 'ESNext',
                                                                                     'moduleResolution': 'Bundler',
                                                                                     'noEmit': True,
                                                                                     'skipLibCheck': True,
                                                                                     'strict': True,
                                                                                     'target': 'ESNext'},
                                                                 'files': ['main.ts']},
                                                      'expected': [('main.ts', 4, 8, 4104)],
                                                      'files': {'main.ts': 'declare const '
                                                                           'data:Record<string,readonly '
                                                                           'number[]>;\n'
                                                                           'for(const [key,value] '
                                                                           'of '
                                                                           'Object.entries(data)){\n'
                                                                           ' const good:readonly '
                                                                           'number[]=value;\n'
                                                                           ' const '
                                                                           'wrong:number[]=value;\n'
                                                                           '}\n'}},
 'library-array-negative-controls/locale-es5': {'config': {'compilerOptions': {'lib': ['ES5'],
                                                                               'module': 'ESNext',
                                                                               'moduleResolution': 'Bundler',
                                                                               'noEmit': True,
                                                                               'skipLibCheck': True,
                                                                               'strict': True,
                                                                               'target': 'ESNext'},
                                                           'files': ['main.ts']},
                                                'expected': [],
                                                'files': {'main.ts': '"a".localeCompare("b", '
                                                                     'undefined, '
                                                                     '{numeric:true});\n'}},
 'library-array-negative-controls/locale-invalid-numeric': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                                                           'module': 'ESNext',
                                                                                           'moduleResolution': 'Bundler',
                                                                                           'noEmit': True,
                                                                                           'skipLibCheck': True,
                                                                                           'strict': True,
                                                                                           'target': 'ESNext'},
                                                                       'files': ['main.ts']},
                                                            'expected': [('main.ts', 1, 34, 2769)],
                                                            'files': {'main.ts': '"a".localeCompare("b",undefined,{numeric:"yes"});\n'}},
 'library-array-negative-controls/locale-invalid-sensitivity': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                                                               'module': 'ESNext',
                                                                                               'moduleResolution': 'Bundler',
                                                                                               'noEmit': True,
                                                                                               'skipLibCheck': True,
                                                                                               'strict': True,
                                                                                               'target': 'ESNext'},
                                                                           'files': ['main.ts']},
                                                                'expected': [('main.ts',
                                                                              1,
                                                                              31,
                                                                              2769)],
                                                                'files': {'main.ts': '"a".localeCompare("b",["en"],{sensitivity:"wrong"});\n'}},
 'library-array-negative-controls/locale-readonly': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                                                    'module': 'ESNext',
                                                                                    'moduleResolution': 'Bundler',
                                                                                    'noEmit': True,
                                                                                    'skipLibCheck': True,
                                                                                    'strict': True,
                                                                                    'target': 'ESNext'},
                                                                'files': ['main.ts']},
                                                     'expected': [],
                                                     'files': {'main.ts': 'declare const '
                                                                          'locales:readonly '
                                                                          'string[];\n'
                                                                          '"a".localeCompare("b",locales);\n'}},
 'library-array-negative-controls/null-entries': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                                                 'module': 'ESNext',
                                                                                 'moduleResolution': 'Bundler',
                                                                                 'noEmit': True,
                                                                                 'skipLibCheck': True,
                                                                                 'strict': True,
                                                                                 'target': 'ESNext'},
                                                             'files': ['main.ts']},
                                                  'expected': [('main.ts', 1, 16, 2769),
                                                               ('main.ts', 2, 16, 2769)],
                                                  'files': {'main.ts': 'Object.entries(null);\n'
                                                                       'Object.entries(undefined);\n'}}}

def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("home", "reference", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    compilers = {"home": args.home.resolve(), "reference": args.reference.resolve()}
    summary = {"compiler_hashes": {n: digest(p) for n, p in compilers.items()},
               "observations": [], "failures": [], "passed": False}
    def save() -> None:
        (root / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    save()
    for name, case in CASES.items():
        expected = sorted(case["expected"])
        for engine, exe in compilers.items():
            directory = root / name / engine
            directory.mkdir(parents=True)
            for file, source in case["files"].items():
                (directory / file).write_text(source)
            (directory / "tsconfig.json").write_text(json.dumps(case["config"], indent=2) + "\n")
            inputs = {str(p.relative_to(directory)): digest(p) for p in directory.rglob("*") if p.is_file()}
            argv = [str(exe), "--project", "tsconfig.json", "--pretty", "false"]
            result = subprocess.run(argv, cwd=directory, capture_output=True, text=True, timeout=45)
            output = result.stdout + result.stderr
            diagnostics = sorted((Path(f).name, int(l), int(c), int(n)) for f,l,c,n in
                re.findall(r"([^\r\n]+?)\((\d+),(\d+)\): error TS(\d+):", output))
            unchanged = inputs == {str(p.relative_to(directory)): digest(p) for p in directory.rglob("*") if p.is_file()}
            passed = (result.returncode == (1 if expected else 0) and diagnostics == expected and unchanged
                      and len(re.findall(r"error TS\d+:", output)) == len(expected))
            summary["observations"].append({"case": name, "engine": engine, "command": argv,
                "input_hashes": inputs, "exit": result.returncode, "stdout": result.stdout,
                "stderr": result.stderr, "diagnostics": diagnostics, "passed": passed})
            if not passed:
                summary["failures"].append(f"{name}/{engine}: {diagnostics}, exit {result.returncode}")
            save()
    summary["passed"] = not summary["failures"]
    save()
    if summary["failures"]:
        raise SystemExit("\n".join(summary["failures"]))
    print(f"All {len(summary['observations'])} library observations passed")


if __name__ == "__main__":
    main()
