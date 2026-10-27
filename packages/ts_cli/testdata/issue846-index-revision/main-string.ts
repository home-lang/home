import { counts } from './owner-string.js';

const read: number = counts.known;
counts.known = 2;
counts['other'] = 2;
void read;
