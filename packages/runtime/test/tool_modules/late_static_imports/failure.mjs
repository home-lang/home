globalThis.lateImportFailure = new Error('real dependency failure');
throw globalThis.lateImportFailure;
