// Writes build/ThirdPartyNotices-desktop.txt: the licenses of the JavaScript packages the Windows app ships (bundled
// into the UI or the main process, plus runtime dependencies) and of Electron. go2rtc and its Go modules are listed
// in App/Resources/Legal/Acknowledgements.txt (GoMobile/licenses.sh); Chromium's notices come with Electron
// (LICENSES.chromium.html next to the app).
import { existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const lock = JSON.parse(readFileSync(join(root, 'package-lock.json'), 'utf8'))
const pkg = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'))

// What ends up in the app: the UI and media libraries (bundled by Vite) and the main process's dependencies.
const roots = ['react', 'react-dom', 'zustand', 'radix-ui', '@fluentui/react-icons', 'mediabunny', ...Object.keys(pkg.dependencies ?? {}), 'electron']
const packages = lock.packages

function find(name, from = '') {
  // Node resolution inside the lockfile: nested node_modules first, then the top level.
  let base = from
  while (true) {
    const key = `${base ? base + '/' : ''}node_modules/${name}`
    if (packages[key]) return key
    if (!base) return null
    const index = base.lastIndexOf('/node_modules/')
    base = index >= 0 ? base.slice(0, index) : ''
  }
}

const seen = new Map()
const queue = roots.map((name) => find(name)).filter(Boolean)
while (queue.length) {
  const key = queue.shift()
  if (seen.has(key)) continue
  const info = packages[key]
  seen.set(key, info)
  if (key.endsWith('node_modules/electron')) continue // only Electron itself, not its build-time downloader
  for (const dependency of Object.keys({ ...(info.dependencies ?? {}), ...(info.peerDependencies ?? {}) })) {
    const next = find(dependency, key)
    if (next && !seen.has(next) && !packages[next].dev === false) queue.push(next)
    else if (next && !seen.has(next)) queue.push(next)
  }
}

function licenseText(directory) {
  if (!existsSync(directory)) return null
  const file = readdirSync(directory).find((name) => /^(licen[cs]e|copying|notice)(\.|$|-)/i.test(name))
  return file ? readFileSync(join(directory, file), 'utf8').trim() : null
}

// Packages whose npm tarball has no license file (only "license" in package.json and "MIT" in the README): the
// LICENSE of their repository, word for word — the MIT text below with the repository's copyright line.
const MIT = `Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.`
const fromRepository = {
  '@fluentui/react-icons': {
    license: 'MIT',
    url: 'https://github.com/microsoft/fluentui-system-icons/blob/main/LICENSE',
    copyright: 'Copyright (c) 2020 Microsoft Corporation',
  },
  'react-remove-scroll-bar': {
    license: 'MIT',
    url: 'https://github.com/theKashey/react-remove-scroll-bar/blob/master/LICENSE',
    copyright: 'Copyright (c) 2025 Anton Korzunov <thekashey@gmail.com>',
  },
}

function repositoryLicense(name, license) {
  const known = fromRepository[name]
  if (!known || known.license !== license) return null
  return `MIT License\n\n${known.copyright}\n\n${MIT}\n\n(The npm package ships no license file; this is ${known.url}.)`
}

const entries = [...seen.keys()]
  .map((key) => {
    const name = key.slice(key.lastIndexOf('node_modules/') + 'node_modules/'.length)
    const info = packages[key]
    const license = info.license ?? 'see text'
    return { name, version: info.version, license, text: licenseText(join(root, key)) ?? repositoryLicense(name, license) }
  })
  .filter((entry, index, all) => all.findIndex((other) => other.name === entry.name && other.version === entry.version) === index)
  .sort((a, b) => a.name.localeCompare(b.name))

// A notice without the license text is not a notice: stop instead of writing "License: MIT" alone.
const missing = entries.filter((entry) => !entry.text)
if (missing.length) {
  console.error('notices: no license text for:')
  for (const entry of missing) console.error(`  ${entry.name} ${entry.version} (${entry.license})`)
  console.error('Add its repository LICENSE to `fromRepository` in scripts/notices.mjs (check the version first).')
  process.exit(1)
}

const header = `Waiting Paws for Windows — third-party software
================================================

The Windows app is built with Electron and the open-source packages below.
mediabunny is used under the Mozilla Public License 2.0 (source: https://github.com/Vanilagy/mediabunny).
`
const body = entries
  .map((entry) => `${entry.name} ${entry.version} — ${entry.license}\n${'-'.repeat(60)}\n${entry.text}\n`)
  .join('\n')
writeFileSync(join(root, 'build', 'ThirdPartyNotices-desktop.txt'), header + '\n' + body)
console.log(`notices: ${entries.length} packages → build/ThirdPartyNotices-desktop.txt`)
