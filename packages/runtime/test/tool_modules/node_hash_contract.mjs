// SHA-256 bytes independently produced by Node v26.10.0.
import crypto, { createHash } from 'node:crypto';
import alias from 'crypto';
import { Buffer } from 'node:buffer';
const oracle = {"node":"v26.10.0","vectors":[{"length":0,"hex":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},{"length":1,"hex":"6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d"},{"length":3,"hex":"b361d0f9a938a2bb4fbdc9c21dc5a859788041b0040919d8a811c1888184f4df"},{"length":55,"hex":"576a1bf8d4478657e6dc4af9398544765c2a92cde28478b019235cfed315fc09"},{"length":56,"hex":"9b20501dfd1d99161c257950f3444f3e49230c351c5c8e0943ef369f85f5205d"},{"length":63,"hex":"30b345906b493f06f69444b6521113511c242f30e29840462950035043682f1e"},{"length":64,"hex":"d8bc63b4fc1156e5e7d95a418b9bf54cd3174bedbc2db40f74895349b229b3c0"},{"length":65,"hex":"1ee23b0fbcaecc1aff4a9e8f1645f35ab2c8e13609cd73b68df8b5e3f63ce073"},{"length":127,"hex":"67d79933e3c9aa8e89f481e071cfca1e9a16c09d7263b5efa3bb01f1a9f8d065"},{"length":128,"hex":"54c9eb041badfd7064645067b107661fed6113197ce2dd066ba69618abd3732f"},{"length":129,"hex":"5b55715b51c54661ed0cbd75ba5b00cf1ffee3b7c113a636eca613d9425116a6"},{"length":1024,"hex":"41a8df8d7a09deeda1ce604e394aca7e77f054f4937b3e51c882a84f67de6d1d"},{"length":4096,"hex":"d010f6d76d0eb4dce5d5b5b34014a8a157ec4380a66c24d7d455a9bf652db14a"}],"strings":[{"input":"","hex":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},{"input":"abc","hex":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"},{"input":"real hash\u0000é😀","hex":"05199b02600f3530fadbc52573cb630ba371bb535a55cbd2209382507566d758"},{"input":"\ud800x","hex":"a87ce46793cc659b79bd187e998f8488635f707d5be0957e1d565981efd2b04b"},{"input":"abcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabc","hex":"d9f5aeb06abebb3be3f38adec9a2e3b94228d52193be923eb4e24c9b56ee0930"}],"encodedHex":"fa2b2513b90c737e49a5c907c1832a0f1de8d1cc1b65b001db9d8c9e093ea374","left":"e29db4c3d5e8cd4ff46d6c113340ce5271f642dbc4b340bbff2404ed332385ee","right":"fe504b805b777b4316668cb717f63c00e20c8c3f0d984f3454440b029b48e180","large":"ad97f87076920684e2ca66fc44e5d322797dc9d64706b174e51b5d0828937043","largeBytes":8388608};
function check(value, message) { if (!value) throw new Error(message); }
check(crypto === alias && crypto.createHash === createHash, 'crypto module identity');
let operations = 0;
for (const vector of oracle.vectors) {
  const data = new Uint8Array(vector.length);
  for (let i = 0; i < data.length; i++) data[i] = i * 7 % 256;
  const window = new Uint8Array(data.length + 4);
  window.set(data, 2);
  const view = window.subarray(2, 2 + data.length);
  for (const input of [Buffer.from(data), data, view, new DataView(window.buffer, 2, data.length)]) {
    const hash = createHash('sha256');
    check(hash.update(input, 'ignored encoding') === hash, 'update chaining');
    check(hash.digest('hex') === vector.hex, 'byte view digest ' + vector.length);
    operations++;
  }
  for (const split of [0, Math.floor(data.length / 2), data.length]) {
    const hash = createHash('SHA256').update(data.subarray(0, split));
    const copy = hash.copy();
    hash.update(data.subarray(split));
    copy.update(data.subarray(split));
    const result = hash.digest();
    check(Buffer.isBuffer(result) && result.toString('hex') === vector.hex, 'raw Buffer digest');
    check(copy.digest('hex') === vector.hex, 'copy boundary digest');
    operations += 2;
  }
}
for (const vector of oracle.strings) {
  check(createHash('sha256').update(vector.input).digest('hex') === vector.hex, 'UTF8 digest');
  operations++;
}
check(createHash('sha256').update('aaff0078', 'hex').digest('hex') === oracle.encodedHex, 'hex input');
operations++;
const prefix = createHash('sha256').update('prefix');
const fork = prefix.copy();
check(prefix.update('left').digest('hex') === oracle.left, 'original branch');
check(fork.update('right').digest('hex') === oracle.right, 'copy branch');
operations += 2;
const mutable = Buffer.from('abc');
const saved = createHash('sha256').update(mutable);
mutable[0] = 0;
check(saved.digest('hex') === oracle.strings[1].hex, 'update consumes bytes before mutation');
operations++;
const large = createHash('sha256');
const chunk = new Uint8Array(65536).fill(97);
for (let i = 0; i < 128; i++) large.update(chunk);
check(large.digest('hex') === oracle.large, 'actual 8 MiB streaming digest');
operations++;
const done = createHash('sha256');
done.digest();
for (const action of [() => done.update('x'), () => done.digest(), () => done.copy()]) {
  let thrown;
  try { action(); } catch (error) { thrown = error; }
  check(thrown?.code === 'ERR_CRYPTO_HASH_FINALIZED', 'finalized hash');
  operations++;
}
for (const value of [undefined, null, 42, true, {}, [], new ArrayBuffer(2)]) {
  const hash = createHash('sha256');
  let thrown;
  try { hash.update(value); } catch (error) { thrown = error; }
  check(thrown instanceof TypeError && thrown.code === 'ERR_INVALID_ARG_TYPE', 'invalid update data');
  check(hash.update('abc').digest('hex') === oracle.strings[1].hex, 'invalid update preserves state');
  operations++;
}
for (const value of [undefined, null, 42, true, {}]) {
  let thrown;
  try { createHash(value); } catch (error) { thrown = error; }
  check(thrown instanceof TypeError && thrown.code === 'ERR_INVALID_ARG_TYPE', 'invalid algorithm type');
  operations++;
}
check(operations === 155, 'SHA-256 operation denominator ' + operations);
