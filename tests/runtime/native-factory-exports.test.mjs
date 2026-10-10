import assert from 'node:assert/strict'
import { Buffer as importedBuffer, isAscii, isUtf8, transcode } from 'node:buffer'
import * as processModule from 'node:process'
import processDefault from 'node:process'
import * as constants from 'node:constants'
import { constants as fsConstants } from 'node:fs'
import { constants as osConstants } from 'node:os'
import { StringDecoder } from 'node:string_decoder'
import { ReadStream, WriteStream, isatty } from 'node:tty'

assert.equal(importedBuffer, Buffer)
assert.equal(processDefault, process)
assert.equal(processModule.default, process)
assert.equal(processModule.env, process.env)
assert.equal(typeof processModule.nextTick, 'function')
assert.equal(constants.O_RDONLY, fsConstants.O_RDONLY)
assert.equal(constants.SIGTERM, osConstants.signals.SIGTERM)
assert.equal(typeof isatty(1), 'boolean')
assert.equal(typeof ReadStream, 'function')
assert.equal(typeof WriteStream, 'function')
assert.equal(isAscii(Buffer.from('home')), true)
assert.equal(isUtf8(Buffer.from('héllo')), true)
assert.equal(transcode(Buffer.from('héllo'), 'utf8', 'utf16le').toString('utf16le'), 'héllo')
const decoder = new StringDecoder('utf8')
assert.equal(decoder.write(Buffer.from([0xe2, 0x82])), '')
assert.equal(decoder.end(Buffer.from([0xac])), '€')
const buffer = Buffer.alloc(32)
buffer.writeBigUInt64LE(0x123456789abcdef0n, 0)
assert.equal(buffer.readBigUInt64LE(0), 0x123456789abcdef0n)
buffer.writeDoubleBE(Math.PI, 8)
assert.equal(buffer.readDoubleBE(8), Math.PI)
const copy = Buffer.from(buffer)
assert(buffer.equals(copy))
assert.equal(buffer.compare(copy), 0)
assert.equal(Buffer.concat([Buffer.from('ho'), Buffer.from('me')]).toString(), 'home')
console.log('native factory export identities, constants, buffer, decoder and terminal APIs passed')
