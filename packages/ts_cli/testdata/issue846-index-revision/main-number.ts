import { counts } from './owner-number.js';

const read: number = counts.known;
counts.known = 2;
counts['other'] = 2;
void read;
