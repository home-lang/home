/** @type {{ known: number; [key: string]: number }} */
export const counts = { known: 1 };
counts['local'] = 'bad';

/** @type {{ inner: { known: number; [key: string]: number } }} */
export const nested = { inner: { known: 2 } };
nested.inner['local'] = 'bad';

/** @type {{ known: number; readonly [key: string]: number }} */
export const readonlyCounts = { known: 3 };
