#!/usr/bin/env node
// Builds resources/bin/go2rtc.exe (Windows x64) for the desktop app: go2rtc with the same Waiting Paws
// changes GoMobile/build.sh puts into the iOS/macOS framework, plus GoMobile/desktop (the executable's main).
// Runs on Windows and Linux (cross-compiles); needs Go 1.24+ and git on PATH.
//
//   node scripts/build-go2rtc.mjs          # or: npm run go2rtc
//   node scripts/build-go2rtc.mjs --test   # also run the tests of the patched packages (host OS)
//
// The go2rtc checkout in build/go2rtc/src is reused: every run first puts it back to the pristine tag
// (tracked files restored, files added by an earlier run removed), then copies and patches again.
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

// GoMobile/xiaomi-cs2/conn.go and GoMobile/mp4/muxer.go are copies of v1.9.14 files:
// port them (and the patches below) before changing the version, as build.sh says.
const GO2RTC_VERSION = 'v1.9.14'
const GO2RTC_REPO = 'https://github.com/AlexxIT/go2rtc'

const DESKTOP = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const GOMOBILE = path.resolve(DESKTOP, '..', 'GoMobile')
const BUILD = path.join(DESKTOP, 'build', 'go2rtc')
const SRC = path.join(BUILD, 'src')
const OUT = path.join(DESKTOP, 'resources', 'bin', 'go2rtc.exe')

// GoMobile dir → place in go2rtc's tree (build.sh plus desktop/ for this executable).
const COPIES = [
  ['xiaomi', 'internal/xiaomi'], // /api/xiaomi/miot, /api/xiaomi/logout, /api/xiaomi/cameras, /api/xiaomi/motor
  ['streams', 'internal/streams'], // Stream.Conns: the motor rides on the stream's camera session
  ['api', 'internal/api'], // API guard, runtime LAN credentials, Relisten
  ['xiaomi-cs2', 'pkg/xiaomi/miss/cs2'], // our CS2 transport (copy of v1.9.14 conn.go)
  ['mp4', 'pkg/mp4'], // recordings keep real time (copy of v1.9.14 muxer.go)
  ['xiaomi-miss', 'pkg/xiaomi/miss'], // Xiaomi sound follows the camera's clock, the pan/tilt step
  ['desktop', 'desktop'], // package main of go2rtc.exe
]

// The sed lines of GoMobile/build.sh as exact string replacements, with sed's line semantics:
//   line: `s|^LINE$|&APPEND|`  — a whole line equal to `line` gets `append`;
//   end:  `s|END$|TO|`        — a line ending with `end` gets that end replaced with `to`;
//   from: `s|FROM|TO|`        — the first `from` on a line becomes `to`.
// Each one must match at least once (it is applied to the pristine file, so a miss means upstream changed).
const PATCHES = [
  // 2a. Recordings keep real time (GoMobile/mp4/muxer.go) and Xiaomi sound follows the camera's clock.
  { file: 'internal/mp4/mp4.go', line: '\tcons := mp4.NewConsumer(medias)', append: '; cons.KeepTimeline() // Waiting Paws: GoMobile/mp4/muxer.go' },
  { file: 'pkg/xiaomi/miss/producer.go', line: '\tvar audioTS uint32', append: '; audio := newAudioClock(p.client) // Waiting Paws: audioclock.go' },
  { file: 'pkg/xiaomi/miss/producer.go', line: '\t\tp.Recv += len(pkt.Payload)', append: '; audioTS = audio.follow(audioTS, pkt) // Waiting Paws' },
  // 2b. 256 frames per viewer instead of 64.
  { file: 'pkg/core/track.go', end: 'bufSize = 64', to: 'bufSize = 256 // Waiting Paws: 64 upstream' },
  // 3. HEVC in MP4 as `hvc1` (Apple only plays hvc1).
  { file: 'pkg/iso/codecs.go', from: 'm.StartAtom("hev1")', to: 'm.StartAtom("hvc1")' },
  { file: 'pkg/iso/reader.go', from: 'case "avc1", "hev1":', to: 'case "avc1", "hev1", "hvc1":' },
  // 4. API guard, runtime Basic-auth credentials, a failed listener is an error instead of log.Fatal.
  { file: 'internal/api/api.go', from: 'Handler = http.DefaultServeMux // 4th', to: 'Handler = guard(http.DefaultServeMux) // 4th' },
  { file: 'internal/api/api.go', from: 'if !ok || user != username || pass != password {', to: 'if !ok || !credentialsOK(user, pass, username, password) {' },
  { file: 'internal/api/api.go', from: 'log.Fatal().Err(err).Msg("[api] serve")', to: 'log.Error().Err(err).Msg("[api] serve")' },
  { file: 'internal/api/api.go', from: 'log.Fatal().Err(err).Msg("[api] tls serve")', to: 'log.Error().Err(err).Msg("[api] tls serve")' },
]

// The greps of build.sh after the seds: [file, text, should it be there, what failed].
const CHECKS = [
  ['internal/mp4/mp4.go', 'cons.KeepTimeline() // Waiting Paws', true, 'stream.mp4 timeline'],
  ['pkg/xiaomi/miss/producer.go', 'audio := newAudioClock(p.client)', true, 'xiaomi audio clock'],
  ['pkg/xiaomi/miss/producer.go', 'audioTS = audio.follow(audioTS, pkt)', true, 'xiaomi audio clock'],
  ['pkg/core/track.go', 'bufSize = 256 // Waiting Paws', true, 'sender buffer'],
  ['pkg/iso/codecs.go', 'StartAtom("hvc1")', true, 'hvc1'],
  ['pkg/iso/reader.go', 'case "avc1", "hev1", "hvc1":', true, 'hvc1 reader'],
  ['internal/api/api.go', 'Handler = guard(http.DefaultServeMux)', true, 'api guard'],
  ['internal/api/api.go', 'credentialsOK(user, pass, username, password)', true, 'api auth'],
  ['internal/api/api.go', 'log.Fatal', false, 'api fatal'],
]

// What GoMobile/README.md and build.sh test after patching (GoMobile tests live in these packages).
const TEST_PACKAGES = ['./pkg/mp4', './pkg/xiaomi/miss', './pkg/xiaomi/miss/cs2', './internal/api', './internal/xiaomi']

function fail(message) {
  console.error(`build-go2rtc: ${message}`)
  process.exit(1)
}

function run(cmd, args, { cwd = SRC, env, quiet = false } = {}) {
  try {
    return execFileSync(cmd, args, {
      cwd,
      env: env ? { ...process.env, ...env } : process.env,
      encoding: 'utf8',
      maxBuffer: 64 << 20,
      stdio: quiet ? ['ignore', 'pipe', 'pipe'] : ['ignore', 'pipe', 'inherit'],
    })
  } catch (e) {
    if (e.code === 'ENOENT') fail(`${cmd} not found on PATH`)
    if (quiet) throw e
    fail(`${cmd} ${args.join(' ')} failed${e.status != null ? ` (exit ${e.status})` : ''}`)
  }
}

const git = (args, opts) => run('git', args, opts)
const lines = (text) => text.split('\n').map((s) => s.trim()).filter(Boolean)

function checkout() {
  let reuse = fs.existsSync(path.join(SRC, '.git'))
  if (reuse) {
    try {
      const head = git(['rev-parse', 'HEAD'], { quiet: true }).trim()
      const tag = git(['rev-parse', `refs/tags/${GO2RTC_VERSION}^{commit}`], { quiet: true }).trim()
      reuse = head === tag
    } catch {
      reuse = false
    }
    if (!reuse) console.log(`${SRC} is not go2rtc ${GO2RTC_VERSION}: cloning again`)
  }
  if (!reuse) {
    fs.rmSync(SRC, { recursive: true, force: true })
    fs.mkdirSync(BUILD, { recursive: true })
    console.log(`Cloning go2rtc ${GO2RTC_VERSION}…`)
    git(['-c', 'advice.detachedHead=false', 'clone', '--quiet', '--depth', '1', '--branch', GO2RTC_VERSION,
      '--config', 'core.autocrlf=false', GO2RTC_REPO, SRC], { cwd: BUILD })
    return
  }

  // Back to the pristine tag, with read-only git: restore changed tracked files, remove added ones.
  const changed = lines(git(['-c', 'core.quotePath=false', 'diff', '--name-only', 'HEAD']))
  const added = lines(git(['-c', 'core.quotePath=false', 'ls-files', '--others', '--exclude-standard']))
  for (const file of changed) {
    const target = path.join(SRC, file)
    fs.mkdirSync(path.dirname(target), { recursive: true })
    fs.writeFileSync(target, execFileSync('git', ['show', `HEAD:${file}`], { cwd: SRC, maxBuffer: 64 << 20 }))
  }
  for (const file of added) fs.rmSync(path.join(SRC, file), { force: true })
  console.log(`Reusing ${SRC} (${changed.length} restored, ${added.length} removed)`)
}

function copyGoMobile() {
  for (const [from, to] of COPIES) {
    const dir = path.join(GOMOBILE, from)
    const files = fs.readdirSync(dir).filter((f) => f.endsWith('.go'))
    if (files.length === 0) fail(`no .go files in ${dir}`)
    fs.mkdirSync(path.join(SRC, to), { recursive: true })
    for (const file of files) fs.copyFileSync(path.join(dir, file), path.join(SRC, to, file))
  }
}

function applyPatch(text, patch) {
  let count = 0
  const out = text.split('\n').map((raw) => {
    const cr = raw.endsWith('\r') ? '\r' : ''
    const line = cr ? raw.slice(0, -1) : raw
    let next = line
    if (patch.line !== undefined && line === patch.line) next = line + patch.append
    else if (patch.end !== undefined && line.endsWith(patch.end)) next = line.slice(0, -patch.end.length) + patch.to
    else if (patch.from !== undefined && line.includes(patch.from)) next = line.replace(patch.from, () => patch.to)
    if (next === line) return raw
    count++
    return next + cr
  })
  if (count === 0) {
    const pattern = patch.line ?? patch.end ?? patch.from
    fail(`patch failed: ${JSON.stringify(pattern)} not found in ${patch.file} (go2rtc ${GO2RTC_VERSION})`)
  }
  return out.join('\n')
}

function patch() {
  const files = new Map()
  const read = (file) => files.get(file) ?? fs.readFileSync(path.join(SRC, file), 'utf8')
  for (const p of PATCHES) files.set(p.file, applyPatch(read(p.file), p))
  for (const [file, text] of files) fs.writeFileSync(path.join(SRC, file), text)
  for (const [file, text, wanted, what] of CHECKS) {
    if (read(file).includes(text) !== wanted) fail(`${what} patch failed (${file})`)
  }
  console.log(`Patched go2rtc: ${PATCHES.length} replacements in ${files.size} files`)
}

function build() {
  const env = { GOOS: 'windows', GOARCH: 'amd64', CGO_ENABLED: '0' }
  // Built next to the sources and moved at the end: a go2rtc.exe that is running (npm run dev) can't be
  // overwritten on Windows, but it can be moved away.
  const tmp = path.join(BUILD, 'go2rtc.exe')
  console.log(`Building ${path.relative(DESKTOP, OUT)} (windows/amd64)…`)
  // -H=windowsgui: no console window even if the parent forgets windowsHide; piped stdout/stderr still work.
  run('go', ['build', '-trimpath', '-ldflags', '-s -w -H=windowsgui', '-o', tmp, './desktop'], { env })

  fs.mkdirSync(path.dirname(OUT), { recursive: true })
  for (const f of fs.readdirSync(BUILD)) {
    if (!/^go2rtc\.old-\d+\.exe$/.test(f)) continue
    try {
      fs.rmSync(path.join(BUILD, f), { force: true })
    } catch {} // still running: next time
  }
  try {
    fs.renameSync(tmp, OUT)
  } catch (e) {
    if (!['EPERM', 'EBUSY', 'EACCES'].includes(e.code)) throw e
    const old = path.join(BUILD, `go2rtc.old-${Date.now()}.exe`)
    fs.renameSync(OUT, old)
    fs.renameSync(tmp, OUT)
    console.log(`The previous go2rtc.exe is running: moved to ${old}`)
  }
}

function test() {
  console.log(`Testing ${TEST_PACKAGES.join(' ')}…`)
  execFileSync('go', ['test', ...TEST_PACKAGES], { cwd: SRC, stdio: 'inherit' })
}

console.log(run('go', ['version'], { cwd: DESKTOP }).trim())
checkout()
copyGoMobile()
patch()
if (process.argv.includes('--test')) {
  try {
    test()
  } catch {
    fail('tests failed')
  }
}
build()
const size = fs.statSync(OUT).size
console.log(`Built ${OUT} (${(size / 1048576).toFixed(1)} MB, ${size} bytes)`)
