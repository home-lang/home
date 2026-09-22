import assert from 'node:assert/strict'
import {
  constants,
  createSign,
  createVerify,
  generateKeyPair,
  generateKeyPairSync,
  sign,
  verify,
} from 'node:crypto'
import { basename } from 'node:path'
import { promisify } from 'node:util'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)

const message = Buffer.from('home native rsa-pss')
const expectedDetails = { modulusLength: 2048, publicExponent: 65537n }

function checkPair({ privateKey, publicKey }, digest = 'sha256', saltLengths = [undefined, 8, 20]) {
  assert.equal(privateKey.type, 'private')
  assert.equal(publicKey.type, 'public')
  assert.equal(privateKey.asymmetricKeyType, 'rsa-pss')
  assert.equal(publicKey.asymmetricKeyType, 'rsa-pss')
  assert.deepEqual(privateKey.asymmetricKeyDetails, expectedDetails)
  assert.deepEqual(publicKey.asymmetricKeyDetails, expectedDetails)

  for (const saltLength of saltLengths) {
    const privateOptions = saltLength === undefined ? privateKey : { key: privateKey, saltLength }
    const signature = sign(digest, message, privateOptions)
    assert.equal(signature.length, 256)
    for (const key of [privateKey, publicKey]) {
      const publicOptions = saltLength === undefined ? key : { key, saltLength }
      assert.equal(verify(digest, message, publicOptions, signature), true)
      assert.equal(verify(digest, Buffer.from('wrong message'), publicOptions, signature), false)
    }
  }

  const streamingSigner = createSign(digest)
  streamingSigner.update(message)
  const streamingSignature = streamingSigner.sign(privateKey)
  const streamingVerifier = createVerify(digest)
  streamingVerifier.update(message)
  assert.equal(streamingVerifier.verify(publicKey, streamingSignature), true)

  for (const key of [privateKey, publicKey]) {
    assert.throws(() => key.export({ format: 'jwk' }), { code: 'ERR_CRYPTO_JWK_UNSUPPORTED_KEY_TYPE' })
    assert.throws(() => key.export({ format: 'pem', type: 'pkcs1' }), { code: 'ERR_CRYPTO_INCOMPATIBLE_KEY_OPTIONS' })
  }
  assert.throws(
    () => sign(digest, message, { key: privateKey, padding: constants.RSA_PKCS1_PADDING }),
    { code: 'ERR_INVALID_ARG_VALUE' },
  )
}

checkPair(generateKeyPairSync('rsa-pss', { modulusLength: 2048, publicExponent: 65537 }))

const restricted = generateKeyPairSync('rsa-pss', {
  modulusLength: 2048,
  publicExponent: 65537,
  hashAlgorithm: 'sha256',
  mgf1HashAlgorithm: 'sha256',
  saltLength: 16,
})
checkPair(restricted, 'sha256', [undefined, 16, 20])
assert.throws(() => sign('sha1', message, restricted.privateKey), /digest not allowed/)
assert.throws(() => sign('sha256', message, { key: restricted.privateKey, saltLength: 8 }), /pss saltlen too small|too small for this RSA-PSS key/)
const wrongDigestSigner = createSign('sha1')
wrongDigestSigner.update(message)
assert.throws(() => wrongDigestSigner.sign(restricted.privateKey), /digest not allowed/)
const wrongDigestVerifier = createVerify('sha1')
wrongDigestVerifier.update(message)
assert.throws(() => wrongDigestVerifier.verify(restricted.publicKey, Buffer.alloc(256)), /digest not allowed/)

const asyncPair = await promisify(generateKeyPair)('rsa-pss', {
  modulusLength: 2048,
  publicExponent: 65537,
  hashAlgorithm: 'sha1',
  mgf1HashAlgorithm: 'sha1',
  saltLength: 20,
})
checkPair(asyncPair, 'sha1', [undefined, 20])

console.log('native RSA-PSS generation and signing passed')
