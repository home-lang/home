import state from './sibling-state.cjs';
state.trace.push('a start');
await state.promise;
state.trace.push('a end');
export const value = 42;
