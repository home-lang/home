import buffer, { Buffer, constants, kMaxLength } from 'node:buffer';
function check(value, message) { if (!value) throw new Error(message); }
let operations = 0;
const descriptor = Object.getOwnPropertyDescriptor(constants, 'MAX_LENGTH');
check(descriptor && !descriptor.writable && !descriptor.configurable && descriptor.enumerable, 'Node MAX_LENGTH descriptor');
operations++;
const moduleDescriptor = Object.getOwnPropertyDescriptor(buffer, 'constants');
check(!moduleDescriptor.writable && !moduleDescriptor.configurable, 'Node constants module descriptor');
operations++;
check(!Reflect.set(constants, 'MAX_LENGTH', 1) && !Reflect.set(buffer, 'constants', { MAX_LENGTH: 1 }), 'read-only properties reject writes');
operations++;
check(buffer.constants === constants && kMaxLength === constants.MAX_LENGTH && Buffer.alloc(3).length === 3, 'failed mutation preserves actual allocation');
operations++;
check(operations === 4, 'Buffer descriptor operation denominator ' + operations);
