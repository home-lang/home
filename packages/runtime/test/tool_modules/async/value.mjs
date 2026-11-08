import trace from './trace.cjs';
trace.push('dependency start');
await Promise.resolve().then(() => trace.push('dependency await'));
export const value = 42;
trace.push('dependency end');
