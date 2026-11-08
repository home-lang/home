import { after, typed } from './comment_boundary.ts';
if (typed(1) !== 2 || after(2) !== 3) {
  throw new Error('comment preservation changed actual module bindings');
}
console.log('OK bounded leading documentation emission');
