require('node:assert').strictEqual(17,42,'actual assertion failure');
throw new Error('assertion silently passed');
