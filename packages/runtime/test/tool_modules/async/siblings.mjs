import { value } from './sibling-a.mjs';
import './sibling-b.mjs';
import state from './sibling-state.cjs';
if (value !== 42 || state.trace.join(',') !== 'a start,b,a end') throw new Error('independent async sibling order: ' + state.trace.join(','));
console.log('OK home-tool independent async siblings');
