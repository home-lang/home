import { join, label } from './owner.js';

label(1);
label(1, 'ok');
label();
label(1, 2);
const badLabel: number = label(1);
join(1, 'a', 'b');
join(1, 'a', 2);
const badJoin: number = join(1);
label(1, 'ok', 'extra');
void [badLabel, badJoin];
