import { counts, nested, readonlyCounts } from './owner.js';

const known: number = counts.known;
const dynamic: number = counts['other'];
counts.known = 'bad';
counts['other'] = 'bad';
counts.other = 3;

const nestedKnown: number = nested.inner.known;
const nestedDynamic: number = nested.inner['other'];
nested.inner.known = 'bad';
nested.inner['other'] = 'bad';
nested.inner.other = 4;
readonlyCounts.known = 5;
readonlyCounts['known'] = 6;
readonlyCounts['other'] = 5;
const readonlyRead: number = readonlyCounts['other'];
void [known, dynamic, nestedKnown, nestedDynamic, readonlyRead];
