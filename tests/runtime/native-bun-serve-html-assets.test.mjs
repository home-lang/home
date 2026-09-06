import assert from 'node:assert/strict'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

const fixtureDir = await mkdtemp(join(tmpdir(), 'home-serve-html-assets-'))

try {
  const htmlPath = join(fixtureDir, 'index.html')
  await Promise.all([
    writeFile(
      htmlPath,
      `<!doctype html>
<html>
  <head>
    <link rel="stylesheet" href="styles.css">
    <script type="module" src="script.js"></script>
  </head>
  <body><p class="message">Home</p></body>
</html>
`,
    ),
    writeFile(join(fixtureDir, 'script.js'), 'console.log("served")\n'),
    writeFile(join(fixtureDir, 'styles.css'), '.message { display: block; }\n'),
  ])

  const html = (await import(pathToFileURL(htmlPath).href)).default
  const server = Bun.serve({
    port: 0,
    static: { '/': html },
    development: { hmr: false },
  })

  try {
    const response = await fetch(server.url)
    assert.equal(response.status, 200)
    const servedHtml = await response.text()
    const scriptPath = servedHtml.match(/src="([^"]+\.js)"/)?.[1]
    const stylesheetPath = servedHtml.match(/href="([^"]+\.css)"/)?.[1]

    assert.match(scriptPath, /^\/chunk-[a-z0-9]+\.js$/)
    assert.match(stylesheetPath, /^\/chunk-[a-z0-9]+\.css$/)

    const scriptResponse = await fetch(new URL(scriptPath, server.url))
    assert.equal(scriptResponse.status, 200)
    const sourceMapPath = scriptResponse.headers.get('sourcemap')
    assert.match(sourceMapPath, /^\/chunk-[a-z0-9]+\.js\.map$/)

    const sourceMapResponse = await fetch(new URL(sourceMapPath, server.url))
    assert.equal(sourceMapResponse.status, 200)
    const sourceMap = await sourceMapResponse.json()
    assert.deepEqual(sourceMap.sources, ['script.js'])

    const stylesheetResponse = await fetch(new URL(stylesheetPath, server.url))
    assert.equal(stylesheetResponse.status, 200)
    const stylesheet = await stylesheetResponse.text()
    assert.match(stylesheet, /display: block;/)
    assert.doesNotMatch(stylesheet, /display: block flow;/)
  } finally {
    await server.stop(true)
  }
} finally {
  await rm(fixtureDir, { recursive: true, force: true })
}

console.log('native Bun.serve HTML asset roots passed')
