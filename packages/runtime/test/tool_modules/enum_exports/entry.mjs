import { Action, Alias, Numeric, Merged, module as Shadow, Group, ordinary, Ordinary } from './provider.ts';
import * as namespace from './provider.ts';

function check(value, message) { if (!value) throw new Error(message); }
check(Action && Action.BuildViews === 'build/views' && Action.BuildDocs === 'build/docs', 'actual exported string enum');
check(Alias === Action && namespace.Action === Action, 'enum export object identity');
check(Numeric && Numeric.Zero === 0 && Numeric.Five === 5 && Numeric.Six === 6, 'actual exported numeric enum');
check(Numeric[0] === 'Zero' && Numeric[5] === 'Five' && Numeric[6] === 'Six', 'actual reverse numeric mappings');
check(Merged && Merged.First === 'first' && Merged.Second === 'second', 'merged enum preserves both declarations');
check(Shadow && Shadow.Value === 'shadowed module binding', 'host module binding remains lexical');
check(Group.Nested && Group.Nested.Value === 'namespace enum value', 'namespace member enum export');
check(ordinary() === 'function export' && new Ordinary().value() === 'class export', 'ordinary declaration exports');
check(!('OnlyType' in namespace), 'type aliases remain erased');
const dynamic = await import('./provider.ts');
check(dynamic.Action === Action && dynamic.Merged === Merged, 'dynamic import shares actual enum objects');
console.log('OK actual string/numeric/merged enum exports, namespace identity and lexical module binding');
