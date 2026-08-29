import assert from 'node:assert/strict'
import { basename } from 'node:path'
import { format, parse } from 'node:url'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)
assert.equal(process.config.variables.v8_enable_i18n_support, 1)

const original = new URL('https://us%40er:pa%3Ass@xn--bcher-kva.de:8443/a%20b?q=%23#part?two')
const originalHref = original.href
for (const auth of [false, true]) {
  for (const fragment of [false, true]) {
    for (const search of [false, true]) {
      for (const unicode of [false, true]) {
        const expected = `https://${auth ? 'us%40er:pa%3Ass@' : ''}${unicode ? 'bücher.de' : 'xn--bcher-kva.de'}:8443/a%20b${search ? '?q=%23' : ''}${fragment ? '#part?two' : ''}`
        assert.equal(format(original, { auth, fragment, search, unicode }), expected)
        assert.equal(original.href, originalHref, 'format must not mutate the URL')
      }
    }
  }
}
for (const option of ['auth', 'fragment', 'search']) {
  for (const value of [false, '', 0, NaN]) {
    assert.equal(format(original, { [option]: value }), format(original, { [option]: false }))
  }
  for (const value of [true, 1, {}, [], undefined, null]) {
    assert.equal(format(original, { [option]: value }), originalHref)
  }
}
for (const value of [true, 1, {}, []]) {
  assert.equal(format(original, { unicode: value }), originalHref.replace('xn--bcher-kva.de', 'bücher.de'))
}
for (const value of [false, '', 0, NaN, undefined, null]) {
  assert.equal(format(original, { unicode: value }), originalHref)
  assert.equal(format(original, value), originalHref)
}
for (const options of [true, 1, 'test', Infinity, [], () => {}, Symbol('options')]) {
  assert.throws(() => format(original, options), { name: 'TypeError', code: 'ERR_INVALID_ARG_TYPE' })
}
assert.equal(format({ hostname: 'example.com', protocol: 'https:', pathname: '/' }, true), 'https://example.com/')

const emptyParts = new URL('https://:pass@xn--bcher-kva.de/?#')
assert.equal(format(emptyParts), 'https://:pass@xn--bcher-kva.de/?#')
assert.equal(format(emptyParts, { auth: false, unicode: true }), 'https://bücher.de/?#')
assert.equal(format(emptyParts, { search: false }), 'https://:pass@xn--bcher-kva.de/#')
assert.equal(format(emptyParts, { fragment: false }), 'https://:pass@xn--bcher-kva.de/?')
assert.equal(format(new URL('tel:123#part?two'), { search: false, unicode: true }), 'tel:123#part?two')
assert.equal(format(new URL('tel:123?q#part'), { search: false, fragment: false }), 'tel:123')
assert.equal(format(new URL('file:///tmp/a?#'), { auth: false, unicode: true }), 'file:///tmp/a?#')
assert.equal(format(new URL('foo://xn--bcher-kva.de/a?'), { unicode: true }), 'foo://bücher.de/a?')
assert.equal(format(new URL('https://[::1]:8443/a'), { unicode: true }), 'https://[::1]:8443/a')

for (const hostname of ['::', '[::]']) {
  assert.equal(format({ protocol: 'http:', hostname, pathname: '/' }), 'http://[::]/')
}
for (const protocol of ['http', 'coap']) {
  const parsed = parse(`${protocol}://u:p@[1080:0:0:0:8:800:200C:417A]:61616/`)
  assert.equal(parsed.hostname, '1080:0:0:0:8:800:200c:417a')
  assert.equal(parsed.host, '[1080:0:0:0:8:800:200c:417a]:61616')
  assert.equal(parsed.href, `${protocol}://u:p@[1080:0:0:0:8:800:200c:417a]:61616/`)
  assert.equal(format(parsed), parsed.href)
}
assert.equal(parse('coap://u:p@[::192.9.5.5]:61616/a').hostname, '::192.9.5.5')
assert.equal(parse('http://127.1').hostname, '127.1')
assert.equal(parse('x://0.0,1.1/').hostname, '0.0,1.1')
assert.equal(parse('https://bücher.de').hostname, 'xn--bcher-kva.de')
assert.throws(() => parse('http://[127.0.0.1\0c8763]:8000/'), { code: 'ERR_INVALID_URL' })
for (const character of ['℀', '＠', '\u00AD']) {
  assert.throws(() => parse(`http://${character}/bad.com/`), { code: 'ERR_INVALID_URL' })
}
assert.equal(format({ pathname: '/a?#', search: '?x=#1##2', hash: 'end' }), '/a%3F%23?x=%231%23%232#end')
assert.equal(format({ protocol: 'file', pathname: '/home/user' }), 'file:///home/user')
assert.equal(format({ pathname: '/', query: { x: ['one', 'two words'], y: null } }), '/?x=one&x=two%20words&y=')
assert.equal(format({ protocol: 'http:', hostname: 'example.com', auth: 'a:b:c', pathname: '/' }), 'http://a:b:c@example.com/')
for (const protocol of ['ws', 'wss']) {
  assert.equal(parse(`${protocol}://example.com`).href, `${protocol}://example.com/`)
}
const controlCharacters = parse('http://a\r" \t\n<\'b:b@c\r\nd/e?f')
assert.equal(controlCharacters.auth, 'a" <\'b:b')
assert.equal(controlCharacters.hostname, 'cd')
assert.equal(controlCharacters.href, 'http://a%22%20%3C\'b:b@cd/e?f')
assert.equal(parse('http://example.com/\tpath?q=\nline').href, 'http://example.com/%09path?q=%0Aline')
for (const protocol of ['javascript', 'javAscript', 'JAVASCRIPT']) {
  const parsed = parse(`${protocol}:alert(1);a='@example.com'`)
  assert.equal(parsed.auth, null)
  assert.equal(parsed.hostname, null)
  assert.equal(parsed.href, "javascript:alert(1);a='@example.com'")
}
console.log('native URL contract regressions passed')
