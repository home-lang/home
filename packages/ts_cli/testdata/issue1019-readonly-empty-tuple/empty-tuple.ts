const empty = [] as const;
const report: string = empty;

const mutable: [] = [];
const acceptsReadonly: readonly [] = mutable;
const rejectsMutable: [] = empty;

export {};
