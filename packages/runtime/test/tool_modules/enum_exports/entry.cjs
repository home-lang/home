const exported = require('./provider.ts');
if (!exported.Action || exported.Action.BuildViews !== 'build/views' || exported.Action !== exported.Alias) throw new Error('actual CJS enum export missing');
if (!exported.Numeric || exported.Numeric[6] !== 'Six') throw new Error('actual CJS reverse enum mapping missing');
if (!exported.Group.Nested || exported.Group.Nested.Value !== 'namespace enum value') throw new Error('actual CJS namespace enum missing');
console.log('OK actual CJS enum exports and namespace members');
