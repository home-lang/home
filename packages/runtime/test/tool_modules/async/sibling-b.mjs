import state from './sibling-state.cjs';
state.trace.push('b');
state.resolve();
