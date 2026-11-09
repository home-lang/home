const fromDot = require('.');
if (fromDot.value !== 63 || fromDot !== require('./index.js') || require.resolve('.') !== require.resolve('./index.js')) throw new Error('current directory index fallback');
