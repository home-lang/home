function maybe(flag: boolean) { return flag ? 1 : undefined; }
const widenedReport: number = maybe(true);

function asserted() { return 1 as const; }
const assertedReport: 2 = asserted();

const contextual: () => 1 = () => 1;
const contextualReport: 2 = contextual();

export {};
