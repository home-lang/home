import assert from 'node:assert/strict'
import { getFips, X509Certificate } from 'node:crypto'
import { constants as fsConstants } from 'node:fs'
import { constants as osConstants, userInfo, getPriority, setPriority } from 'node:os'

const config = process.binding('config')
assert.equal(config.fipsMode, Boolean(getFips()))
assert.equal(process.binding('config'), config)
const cryptoBinding = process.binding('crypto/x509')
assert.equal(process.binding('crypto/x509'), cryptoBinding)
assert.equal(cryptoBinding.isX509Certificate({}), false)
const constants = process.binding('constants')
assert.equal(constants, process.binding('constants'))
assert.equal(constants.fs.O_RDONLY, fsConstants.O_RDONLY)
assert.equal(constants.os.signals.SIGTERM, osConstants.signals.SIGTERM)
const uv = process.binding('uv')
assert.equal(uv, process.binding('uv'))
assert.equal(uv.errname(uv.UV_EACCES), 'EACCES')
assert.equal(uv.getErrorMap().get(uv.UV_EACCES)[0], 'EACCES')
assert.throws(() => getPriority('invalid'), { code: 'ERR_INVALID_ARG_TYPE' })
assert.throws(() => setPriority(null, 0), { code: 'ERR_INVALID_ARG_TYPE' })
assert.throws(() => getPriority(3.14), { code: 'ERR_OUT_OF_RANGE' })
const getterError = new Error('user-info-option-getter')
assert.throws(() => userInfo({ get encoding() { throw getterError } }), error => error === getterError)
const account = userInfo()
const saved = { USER: process.env.USER, HOME: process.env.HOME, SHELL: process.env.SHELL }
try {
  process.env.USER = 'home-test-environment-user'
  process.env.HOME = '/home-test-environment-home'
  process.env.SHELL = '/home-test-environment-shell'
  assert.deepEqual(userInfo(), account)
} finally {
  for (const [name, value] of Object.entries(saved)) {
    if (value === undefined) delete process.env[name]
    else process.env[name] = value
  }
}
const accountBuffers = userInfo({ encoding: 'buffer' })
assert(Buffer.isBuffer(accountBuffers.username))
assert.equal(accountBuffers.username.toString(), account.username)
assert(Buffer.isBuffer(accountBuffers.homedir))
assert.equal(accountBuffers.homedir.toString(), account.homedir)
Bun.gc(true)
assert.equal(process.binding('config'), config)
assert.equal(process.binding('crypto/x509'), cryptoBinding)
assert.equal(typeof X509Certificate, 'function')
console.log('native process binding state, FIPS capability, constants, UV and GC identity passed')
