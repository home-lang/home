if (require('@app/exact') !== 'nearest config') throw new Error('nearest config');
let missing = false; try { require('@fallback'); } catch { missing = true; }
if (!missing) throw new Error('parent aliases leaked');
console.log('OK home-tool nearest tsconfig paths');
