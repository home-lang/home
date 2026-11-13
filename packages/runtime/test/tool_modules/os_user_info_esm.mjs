import os, {userInfo} from 'node:os';
import legacy, {userInfo as legacyUserInfo} from 'os';
const expected = JSON.parse(process.env.HOME_TOOL_ACCOUNT_ORACLE);
const user = userInfo({encoding: 'buffer'});
const same = userInfo === os.userInfo && userInfo === legacyUserInfo && os === legacy;
const physical = user.uid === expected.uid && user.gid === expected.gid && ['username', 'homedir', 'shell'].every(key => Buffer.isBuffer(user[key]) && user[key].toString('hex') === expected.rawHex[key]);
console.log(JSON.stringify({same, physical}));
