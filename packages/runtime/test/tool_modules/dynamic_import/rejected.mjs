globalThis.dynamicFailureExecutions = (globalThis.dynamicFailureExecutions || 0) + 1;
await Promise.resolve();
throw globalThis.dynamicFailure;
