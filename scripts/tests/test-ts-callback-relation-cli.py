#!/usr/bin/env python3
"""Compare complete callback method relations and conditional object keys with TypeScript.

Run this script under scripts/run-bounded.pl, like the shared CLI harness.
"""
from pathlib import Path
import runpy

CASES = {'callback-renamed-negative': ({'main.ts': 'interface Left{run(listener:(n:string)=>void):void}interface '
                                           'Right{run(observer:(n:number)=>void):void}declare const '
                                           'left:Left;const wrong:Right=left;'},
                               [2322]),
 'callback-second-negative': ({'main.ts': 'interface '
                                          'Left{run(flag:boolean,listener:(n:string)=>void):void}interface '
                                          'Right{run(flag:boolean,observer:(n:number)=>void):void}declare const '
                                          'left:Left;const wrong:Right=left;'},
                              [2322]),
 'callback-result-negative': ({'main.ts': 'interface Left{run(listener:(n:number)=>string):void}interface '
                                          'Right{run(observer:(n:number)=>number):void}declare const '
                                          'left:Left;const wrong:Right=left;'},
                              [2322]),
 'callback-void-source-positive': ({'main.ts': 'interface Left{run(listener:(n:number)=>void):void}interface '
                                               'Right{run(observer:(n:number)=>number):void}declare const '
                                               'left:Left;const good:Right=left;'},
                                   []),
 'callback-void-target-negative': ({'main.ts': 'interface Left{run(listener:(n:number)=>number):void}interface '
                                               'Right{run(observer:(n:number)=>void):void}declare const '
                                               'left:Left;const wrong:Right=left;'},
                                   [2322]),
 'callback-extra-required-negative': ({'main.ts': 'interface '
                                                  'Left{run(listener:(n:number)=>void,flag:boolean):void}interface '
                                                  'Right{run(observer:(n:number)=>void):void}declare const '
                                                  'left:Left;const wrong:Right=left;'},
                                      [2322]),
 'callback-extra-optional-positive': ({'main.ts': 'interface '
                                                  'Left{run(listener:(n:number)=>void,flag?:boolean):void}interface '
                                                  'Right{run(observer:(n:number)=>void):void}declare const '
                                                  'left:Left;const good:Right=left;'},
                                      []),
 'callback-parameter-arity-negative': ({'main.ts': 'interface Left{run(listener:(n:number)=>void):void}interface '
                                                   'Right{run(observer:(n:number,m:number)=>void):void}declare '
                                                   'const left:Left;const wrong:Right=left;'},
                                       [2322]),
 'callback-parameter-optional-positive': ({'main.ts': 'interface '
                                                      'Left{run(listener:(n:number)=>void):void}interface '
                                                      'Right{run(observer:(n:number,m?:number)=>void):void}declare '
                                                      'const left:Left;const good:Right=left;'},
                                          []),
 'callback-rest-tail-negative': ({'main.ts': 'interface '
                                             'Left{run(listener:(n:number)=>void,...tail:string[]):void}interface '
                                             'Right{run(observer:(n:number)=>void,...tail:number[]):void}declare '
                                             'const left:Left;const wrong:Right=left;'},
                                 [2322]),
 'callback-nested-object-extra-negative': ({'main.ts': 'type Shape<T>={nested:{known:T extends '
                                                       'string?number:boolean}};declare function '
                                                       'take<T>(value:Shape<T>):void;function '
                                                       'use<T>():void{take<T>({nested:{known:null as '
                                                       'any,extra:true}});}'},
                                           [2353]),
 'callback-nested-conditional-positive': ({'main.ts': 'type Shape<T>={known:T extends '
                                                      'string?number:boolean};declare function '
                                                      'take<T>(value:Shape<T>):void;function '
                                                      'use<T>():void{take<T>({known:null as any});}'},
                                          []),
 'callback-method-conditional-extra-negative': ({'main.ts': 'type Shape<T>={read():T extends '
                                                            'string?number:boolean};declare function '
                                                            'take<T>(value:Shape<T>):void;function '
                                                            'use<T>():void{take<T>({read:()=>null as '
                                                            'any,extra:true});}'},
                                                [2353]),
 'generic-callback-argument-positive': ({'main.ts': 'type One<T>={set(value:T):void};type '
                                                    'Two<T>={set(value:T):void};declare let '
                                                    'left:One<(value:unknown)=>void>;declare let '
                                                    'right:Two<(value:string)=>void>;left=right;right=left;'},
                                        []),
 'direct-callback-covariance': ({'main.ts': 'interface A{a:number}interface B extends A{b:number}interface '
                                            'Left{run(listener:(value:A)=>void):void}interface '
                                            'Right{run(observer:(value:B)=>void):void}declare let '
                                            'left:Left;declare let right:Right;left=right;right=left;'},
                                [2322]),
 'property-callback-variance': ({'main.ts': 'interface A{a:number}interface B extends A{b:number}interface '
                                            'Left{run:(listener:(value:A)=>void)=>void}interface '
                                            'Right{run:(observer:(value:B)=>void)=>void}declare let '
                                            'left:Left;declare let right:Right;left=right;right=left;'},
                                [2322]),
 'direct-callback-return-bivariance-positive': ({'main.ts': 'interface A{a:number}interface B extends '
                                                            'A{b:number}interface '
                                                            'Left{run(listener:()=>A):void}interface '
                                                            'Right{run(observer:()=>B):void}declare let '
                                                            'left:Left;declare let '
                                                            'right:Right;left=right;right=left;'},
                                                []),
 'property-callback-return-contravariance-negative': ({'main.ts': 'interface A{a:number}interface B extends '
                                                                  'A{b:number}interface '
                                                                  'Left{run:(listener:()=>A)=>void}interface '
                                                                  'Right{run:(observer:()=>B)=>void}declare let '
                                                                  'left:Left;declare let '
                                                                  'right:Right;left=right;right=left;'},
                                                      [2322]),
 'optional-callback-covariance-negative': ({'main.ts': 'interface A{a:number}interface B extends '
                                                       'A{b:number}interface '
                                                       'Left{run(listener?:((value:A)=>void)):void}interface '
                                                       'Right{run(observer?:((value:B)=>void)):void}declare let '
                                                       'left:Left;declare let right:Right;left=right;right=left;'},
                                           [2322]),
 'callback-predicate-assignment-negative': ({'main.ts': 'interface A{a:number}interface B extends '
                                                        'A{b:number}interface Left{run(listener:(value:A)=>value '
                                                        'is A):void}interface Right{run(observer:(value:B)=>value '
                                                        'is B):void}declare let left:Left;declare let '
                                                        'right:Right;left=right;right=left;'},
                                            [2322, 2322]),
 'imported-generic-callback-argument-positive': ({'owner.ts': 'export type One<T>={set(value:T):void};export type '
                                                              'Two<T>={set(value:T):void};',
                                                  'main.ts': 'import type {One,Two} from "./owner";declare let '
                                                             'left:One<(value:unknown)=>void>;declare let '
                                                             'right:Two<(value:string)=>void>;left=right;right=left;'},
                                                 []),
 'imported-callback-predicate-negative': ({'owner.ts': 'export interface A{a:number}export interface B extends '
                                                       'A{b:number}export interface '
                                                       'Left{run(listener:(value:A)=>value is A):void}export '
                                                       'interface Right{run(observer:(value:B)=>value is B):void}',
                                           'main.ts': 'import type {Left,Right} from "./owner";declare let '
                                                      'left:Left;declare let right:Right;left=right;right=left;'},
                                          [2322, 2322]),
 'callback-nullability-mismatch-negative': ({'main.ts': 'interface A{a:number}interface B extends '
                                                        'A{b:number}interface '
                                                        'Left{run(listener:((value:A)=>void)|undefined):void}interface '
                                                        'Right{run(observer:(value:B)=>void):void}declare let '
                                                        'left:Left;declare let '
                                                        'right:Right;left=right;right=left;'},
                                            [2322, 2322]),
 'callback-attached-property-positive': ({'main.ts': 'interface A{a:number}interface B extends '
                                                     'A{b:number}interface '
                                                     'Left{run(listener:{(value:A):void;tag:string}):void}interface '
                                                     'Right{run(observer:{(value:B):void;tag:string}):void}declare '
                                                     'let left:Left;declare let '
                                                     'right:Right;left=right;right=left;'},
                                         []),
 'callback-normal-parameter-bivariance-positive': ({'main.ts': 'interface A{a:number}interface B extends '
                                                               'A{b:number}interface '
                                                               'Left{run(listener:(value:number)=>void,input:A):void}interface '
                                                               'Right{run(observer:(value:number)=>void,input:B):void}declare '
                                                               'let left:Left;declare let '
                                                               'right:Right;left=right;right=left;'},
                                                   [])}

CASES.update({
    'conditional-sibling-value-negative': ({'main.ts': 'type Shape<T>={known:number;maybe:T extends string?number:boolean};declare function take<T>(value:Shape<T>):void;function use<T>():void{take<T>({known:"bad",maybe:null as any});}'}, [2322]),
    'callback-this-negative': ({'main.ts': 'interface A{a:number}interface B{b:number}interface Left{run(listener:(this:A,n:number)=>void):void}interface Right{run(observer:(this:B,n:number)=>void):void}declare let left:Left;declare let right:Right;left=right;right=left;'}, [2322,2322]),
    'callback-this-bivariance-positive': ({'main.ts': 'interface A{a:number}interface B extends A{b:number}interface Left{run(listener:(this:A,n:number)=>void):void}interface Right{run(observer:(this:B,n:number)=>void):void}declare let left:Left;declare let right:Right;left=right;right=left;'}, []),
})

CASES.update({'generic-rest-array-positive': ({'main.ts': 'type One<T>={set(...values:T[]):void};type '
                                             'Two<T>={set(...values:T[]):void};declare let '
                                             'left:One<(value:unknown)=>void>;declare let '
                                             'right:Two<(value:string)=>void>;left=right;right=left;'},
                                 []),
 'generic-rest-tuple-positive': ({'main.ts': 'type One<T>={set(...values:[number,T]):void};type '
                                             'Two<T>={set(...values:[number,T]):void};declare let '
                                             'left:One<(value:unknown)=>void>;declare let '
                                             'right:Two<(value:string)=>void>;left=right;right=left;'},
                                 []),
 'generic-rest-tuple-mixed-negative': ({'main.ts': 'interface A{a:number}interface B extends A{b:number}type '
                                                   'One<T>={set(...values:[(value:A)=>void,T]):void};type '
                                                   'Two<T>={set(...values:[(value:B)=>void,T]):void};declare let '
                                                   'left:One<(value:unknown)=>void>;declare let '
                                                   'right:Two<(value:string)=>void>;left=right;right=left;'},
                                       [2322]),
 'direct-rest-array-covariance-negative': ({'main.ts': 'interface A{a:number}interface B extends '
                                                       'A{b:number}interface '
                                                       'Left{set(...values:((value:A)=>void)[]):void}interface '
                                                       'Right{set(...values:((value:B)=>void)[]):void}declare let '
                                                       'left:Left;declare let right:Right;left=right;right=left;'},
                                           [2322]),
 'generic-alias-argument-positive': ({'main.ts': 'type Identity<T>=T;type '
                                                 'One<T>={set(value:Identity<T>):void};type '
                                                 'Two<T>={set(value:Identity<T>):void};declare let '
                                                 'left:One<(value:unknown)=>void>;declare let '
                                                 'right:Two<(value:string)=>void>;left=right;right=left;'},
                                     []),
 'callback-assertion-void-method-positive': ({'main.ts': 'interface '
                                                         'Left{run(listener:(value:unknown)=>void):void}interface '
                                                         'Right{run(observer:(value:unknown)=>asserts value is '
                                                         'string):void}declare let left:Left;declare let '
                                                         'right:Right;left=right;right=left;'},
                                             []),
 'callback-assertion-void-property-positive': ({'main.ts': 'interface '
                                                           'Left{run:(listener:(value:unknown)=>void)=>void}interface '
                                                           'Right{run:(observer:(value:unknown)=>asserts value is '
                                                           'string)=>void}declare let left:Left;declare let '
                                                           'right:Right;left=right;right=left;'},
                                               [])})

def main() -> None:
    root = Path(__file__).resolve().parents[2]
    upstream = root / '_submodules/typescript-go/_submodules/TypeScript/tests/cases/conformance/types/typeRelationships/assignmentCompatibility/covariantCallbacks.ts'
    cases = {**CASES, 'upstream-covariant-callbacks': ({'main.ts': upstream.read_text()}, [2322] * 8)}
    harness = runpy.run_path(str(root / 'scripts/tests/test-ts-polymorphic-this-cli.py'))
    harness['CASES'].clear()
    harness['CASES'].update(cases)
    harness['main']()

if __name__ == '__main__':
    main()
