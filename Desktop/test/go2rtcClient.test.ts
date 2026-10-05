// Not in the Swift suite: the go2rtc client against a fake fetch, URLs, names, and the localization helpers.
import { afterEach, describe, expect, it } from 'vitest'
import {
  Go2RTCClient,
  Go2RTCError,
  Go2RTCServer,
  MiotSpecProvider,
  XiaomiCameraError,
  XiaomiRegion,
  detectCoreLanguage,
  formatDate,
  pluralText,
  setCoreLanguage,
  setCoreRegion,
} from '@core/index'
import { MemoryStorage } from './memoryStorage'

interface Call {
  method: string
  url: string
  headers: Record<string, string>
  body: string | undefined
}

function fakeFetch(routes: Record<string, (call: Call) => Response | Promise<Response>>) {
  const calls: Call[] = []
  const fetch = (async (input: Parameters<typeof globalThis.fetch>[0], init?: RequestInit) => {
    const url = String(input)
    const call: Call = {
      method: init?.method ?? 'GET',
      url,
      headers: (init?.headers ?? {}) as Record<string, string>,
      body: init?.body as string | undefined,
    }
    calls.push(call)
    const path = new URL(url).pathname
    const route = routes[`${call.method} ${path}`]
    return route ? route(call) : new Response('not found', { status: 404 })
  }) as typeof globalThis.fetch
  return { fetch, calls }
}

const json = (value: unknown, status = 200) =>
  new Response(JSON.stringify(value), { status, headers: { 'Content-Type': 'application/json' } })

const server = Go2RTCServer.make('http://192.168.1.5:1984/', 'admin', 'p@ss word')

describe('Go2RTCServer', () => {
  it('parses addresses', () => {
    expect(Go2RTCServer.parse(' 192.168.1.5:1984 ')).toBe('http://192.168.1.5:1984/')
    expect(Go2RTCServer.parse('https://cam.example.org/go2rtc')).toBe('https://cam.example.org/go2rtc/')
    expect(Go2RTCServer.parse('')).toBeNull()
    expect(Go2RTCServer.parse('http://')).toBeNull()
  })

  it('builds credentials', () => {
    expect(Go2RTCServer.authorizationHeader(server)).toBe('Basic ' + Buffer.from('admin:p@ss word').toString('base64'))
    expect(Go2RTCServer.authorizationHeader(Go2RTCServer.make('http://h/'))).toBeNull()
    expect(Go2RTCServer.urlWithCredentials(server)).toBe('http://admin:p%40ss%20word@192.168.1.5:1984/')
  })
})

describe('Go2RTCClient URLs and names', () => {
  const client = new Go2RTCClient(server)

  it('builds API URLs', () => {
    expect(client.url('api/streams')).toBe('http://192.168.1.5:1984/api/streams')
    expect(client.mp4URL('кухня 1')).toBe(
      'http://192.168.1.5:1984/api/stream.mp4?src=%D0%BA%D1%83%D1%85%D0%BD%D1%8F%201&video=h264%2Ch265&audio=aac%2Copus%2Cpcma%2Cpcmu',
    )
    expect(client.snapshotURL('hall')).toBe('http://192.168.1.5:1984/api/frame.jpeg?src=hall')
    expect(client.hlsURL('hall')).toBe('http://192.168.1.5:1984/api/stream.m3u8?src=hall')
    expect(client.playerSocketURL('hall')).toBe('ws://admin:p%40ss%20word@192.168.1.5:1984/api/ws?src=hall')
    expect(client.playerScriptURL()).toBe('http://admin:p%40ss%20word@192.168.1.5:1984/video-rtc.js')
    expect(new Go2RTCClient(Go2RTCServer.make('https://h/base/')).playerSocketURL('a&b')).toBe('wss://h/base/api/ws?src=a%26b')
  })

  it('encodes forms', () => {
    expect(Go2RTCClient.formEncode({ username: 'a+b@c.d', password: "p&=!'()* ~" })).toBe(
      'username=a%2Bb%40c.d&password=p%26%3D%21%27%28%29%2A%20~',
    )
  })

  it('makes stream names like ICU Any-Latin', () => {
    expect(Go2RTCClient.streamName('Гостиная')).toBe('gostinaa')
    expect(Go2RTCClient.streamName('Запись')).toBe('zapis')
    expect(Go2RTCClient.streamName('Прихожая — Ёлка')).toBe('prihozaa-elka')
    expect(Go2RTCClient.streamName('Café #2')).toBe('cafe-2')
    expect(Go2RTCClient.streamName('  ')).toBe('camera')
  })

  it('suggests a Mi Home region', () => {
    setCoreRegion('KZ')
    expect(XiaomiRegion.suggested()).toBe('ru')
    setCoreRegion('GB')
    expect(XiaomiRegion.suggested()).toBe('de')
    setCoreRegion(null)
    setCoreLanguage('ru')
    expect(XiaomiRegion.suggested()).toBe('ru')
  })
})

describe('Go2RTCClient requests', () => {
  afterEach(() => setCoreLanguage('ru'))

  it('lists streams sorted with their producers and sends Basic auth', async () => {
    const { fetch, calls } = fakeFetch({
      'GET /api/streams': () =>
        json({ zeta: { producers: [{ url: 'rtsp://z' }] }, Alpha: { producers: [{ url: 'xiaomi://1' }, {}] }, beta: null }),
    })
    const streams = await new Go2RTCClient(server, { fetch }).streams()
    expect(streams).toEqual([
      { name: 'Alpha', sources: ['xiaomi://1'] },
      { name: 'beta', sources: [] },
      { name: 'zeta', sources: ['rtsp://z'] },
    ])
    expect(calls[0].headers.Authorization).toBe(Go2RTCServer.authorizationHeader(server))
  })

  it('adds and deletes streams with query items', async () => {
    const { fetch, calls } = fakeFetch({ 'PUT /api/streams': () => json({}), 'DELETE /api/streams': () => json({}) })
    const client = new Go2RTCClient(server, { fetch })
    await client.addStream('hall', 'xiaomi://1:cn@10.0.0.2?did=9&model=x')
    await client.deleteStream('hall')
    expect(calls.map((c) => [c.method, new URL(c.url).searchParams.get('src')])).toEqual([
      ['PUT', 'xiaomi://1:cn@10.0.0.2?did=9&model=x'],
      ['DELETE', 'hall'],
    ])
  })

  it('throws typed HTTP errors', async () => {
    setCoreLanguage('en')
    const { fetch } = fakeFetch({ 'GET /api/streams': () => new Response('', { status: 401 }) })
    const error = await new Go2RTCClient(server, { fetch }).streams().catch((e: unknown) => e)
    expect(error).toBeInstanceOf(Go2RTCError)
    expect((error as Go2RTCError).kind).toBe('http')
    expect((error as Go2RTCError).status).toBe(401)
    expect((error as Error).message).toBe('The server answered HTTP 401')
  })

  it('wraps network failures', async () => {
    const fetch = (async () => {
      throw new TypeError('fetch failed', { cause: new Error('connect ECONNREFUSED') })
    }) as typeof globalThis.fetch
    const error = await new Go2RTCClient(server, { fetch }).version().catch((e: unknown) => e)
    expect(error).toBeInstanceOf(Go2RTCError)
    expect((error as Go2RTCError).kind).toBe('network')
    expect((error as Error).message).toBe('fetch failed: connect ECONNREFUSED')
  })

  it('walks the Xiaomi login steps', async () => {
    const replies = [
      json({ captcha: Buffer.from([0x89, 0x50, 0x4e, 0x47]).toString('base64') }, 401),
      json({ verify_phone: '+7 *** ** 12', verify_email: '' }, 401),
      json({}, 401),
      new Response('', { status: 200 }),
    ]
    const { fetch, calls } = fakeFetch({ 'POST /api/xiaomi': () => replies.shift()! })
    const client = new Go2RTCClient(server, { fetch })
    expect(await client.xiaomiLogin('user@example.org', 'пароль')).toEqual({
      kind: 'captcha',
      image: new Uint8Array([0x89, 0x50, 0x4e, 0x47]),
    })
    expect(await client.xiaomiSubmitCaptcha('abcd')).toEqual({ kind: 'verify', phone: '+7 *** ** 12', email: null })
    const rejected = await client.xiaomiSubmitVerify('000000').catch((e: unknown) => e)
    expect((rejected as Error).message).toBe('HTTP 401: Xiaomi отклонил вход: проверьте логин и пароль')
    expect(await client.xiaomiSubmitVerify('123456')).toEqual({ kind: 'success' })
    expect(calls[0].headers['Content-Type']).toBe('application/x-www-form-urlencoded')
    expect(new URLSearchParams(calls[0].body).get('password')).toBe('пароль')
    expect(calls[1].body).toBe('captcha=abcd')
  })

  it('falls back to /api/xiaomi for cameras and reports none', async () => {
    const { fetch, calls } = fakeFetch({
      'GET /api/xiaomi': () => json({ sources: [{ name: 'Кухня', info: 'C302', url: 'xiaomi://k' }, { url: 'xiaomi://x' }, { name: 'no url' }] }),
    })
    const cameras = await new Go2RTCClient(server, { fetch }).xiaomiCameras('123', 'ru')
    expect(cameras).toEqual([
      { name: 'Кухня', info: 'C302', url: 'xiaomi://k' },
      { name: 'xiaomi://x', info: null, url: 'xiaomi://x' },
    ])
    expect(calls.map((c) => new URL(c.url).pathname)).toEqual(['/api/xiaomi/cameras', '/api/xiaomi'])
    expect(new URL(calls[1].url).searchParams.get('region')).toBe('ru')

    const none = fakeFetch({})
    const error = await new Go2RTCClient(server, { fetch: none.fetch }).xiaomiCameras('1', 'cn').catch((e: unknown) => e)
    expect(Go2RTCError.noSources().equals(error)).toBe(true)
  })

  it('lists accounts and reads configured sources', async () => {
    const { fetch } = fakeFetch({
      'GET /api/xiaomi': () => json(['2', '1']),
      'GET /api/config': () => new Response('streams:\n  hall: xiaomi://1\n  yard:\n    - rtsp://y\n'),
    })
    const client = new Go2RTCClient(server, { fetch })
    expect(await client.xiaomiAccounts()).toEqual(['1', '2'])
    expect(await client.configuredSources('hall')).toEqual(['xiaomi://1'])
    expect(await client.configuredSourcesOf(['hall', 'yard', 'none'])).toEqual({
      hall: ['xiaomi://1'],
      yard: ['rtsp://y'],
      none: [],
    })
  })

  it('reads and writes camera settings over MIoT', async () => {
    let lastForm: URLSearchParams | null = null
    const { fetch } = fakeFetch({
      'POST /api/xiaomi/miot': (call) => {
        lastForm = new URLSearchParams(call.body)
        return lastForm.get('method') === 'get'
          ? json([
              { siid: 2, piid: 3, code: 0, value: 2 },
              { siid: 2, piid: 5, code: 0, value: true },
              { siid: 2, piid: 9, code: 0, value: '00:00-23:59' },
              { siid: 4, piid: 1, code: -704042011 },
            ])
          : json([{ siid: 2, piid: 3, code: -704083036 }])
      },
    })
    const client = new Go2RTCClient(server, { fetch })
    const values = await client.xiaomiProperties('xiaomi://k', [
      { siid: 2, piid: 3 },
      { siid: 2, piid: 5 },
      { siid: 2, piid: 9 },
      { siid: 4, piid: 1 },
    ])
    expect(values).toEqual({ '2.3': 2, '2.5': true })
    expect(JSON.parse(lastForm!.get('params')!)).toEqual([
      { siid: 2, piid: 3 },
      { siid: 2, piid: 5 },
      { siid: 2, piid: 9 },
      { siid: 4, piid: 1 },
    ])
    const error = await client.setXiaomiProperty('xiaomi://k', { siid: 2, piid: 3 }, 1).catch((e: unknown) => e)
    expect(XiaomiCameraError.offline().equals(error)).toBe(true)
    expect(JSON.parse(lastForm!.get('params')!)).toEqual([{ siid: 2, piid: 3, value: 1 }])
    expect(await client.xiaomiProperties('xiaomi://k', [])).toEqual({})
  })
})

describe('MiotSpecProvider', () => {
  const index = JSON.stringify({ instances: [{ model: 'm.cam', version: 1, type: 'urn:miot-spec-v2:device:camera:1:m-cam:1' }] })
  const spec = JSON.stringify({
    services: [
      {
        iid: 2,
        type: 'urn:miot-spec-v2:service:camera-control:0000782F:m-cam:1',
        properties: [{ iid: 5, type: 'urn:miot-spec-v2:property:time-watermark:0:m-cam:1', format: 'bool', access: ['read', 'write'] }],
      },
    ],
  })

  it('downloads once, caches on disk and in memory', async () => {
    const storage = new MemoryStorage()
    const { fetch, calls } = fakeFetch({
      'GET /miot-spec-v2/instances': () => new Response(index),
      'GET /miot-spec-v2/instance': () => new Response(spec),
    })
    const provider = new MiotSpecProvider({ cacheDirectory: '/cache', storage, fetch })
    const [a, b] = await Promise.all([provider.cameraModes('m.cam'), provider.cameraModes('m.cam')])
    expect(a.map((o) => o.setting)).toEqual(['timeWatermark'])
    expect(b).toBe(a)
    expect(calls.map((c) => c.url)).toEqual([
      'https://miot-spec.org/miot-spec-v2/instances?status=released',
      'https://miot-spec.org/miot-spec-v2/instance?type=urn%3Amiot-spec-v2%3Adevice%3Acamera%3A1%3Am-cam%3A1',
    ])
    expect([...storage.files.keys()].sort()).toEqual(['/cache/instances.json', '/cache/m.cam.json'])

    // A new provider reads the disk cache; an unknown model with a fresh index is not looked up again.
    const offline = fakeFetch({})
    const again = new MiotSpecProvider({ cacheDirectory: '/cache', storage, fetch: offline.fetch, now: () => 1000 })
    expect((await again.cameraModes('m.cam')).map((o) => o.setting)).toEqual(['timeWatermark'])
    expect(await again.cameraModes('other.cam')).toEqual([])
    expect(offline.calls).toHaveLength(0)
    expect(MiotSpecProvider.fileName('a b/c.d-e')).toBe('a_b_c.d-e')
  })
})

describe('localization', () => {
  afterEach(() => setCoreLanguage('ru'))

  it('plural forms', () => {
    setCoreLanguage('ru')
    const ru = { one: 'выход', few: 'выхода', many: 'выходов' }
    const en = { one: 'exit', other: 'exits' }
    expect([1, 2, 5, 11, 12, 21, 22, 25, 111, 0].map((n) => pluralText(n, ru, en))).toEqual([
      '1 выход', '2 выхода', '5 выходов', '11 выходов', '12 выходов', '21 выход', '22 выхода', '25 выходов',
      '111 выходов', '0 выходов',
    ])
    setCoreLanguage('en')
    expect([1, 2, 0].map((n) => pluralText(n, ru, en))).toEqual(['1 exit', '2 exits', '0 exits'])
  })

  it('detects the app language like Bundle.preferredLocalizations', () => {
    expect(detectCoreLanguage(['de-DE', 'ru-RU'])).toBe('ru')
    expect(detectCoreLanguage(['en-GB', 'ru'])).toBe('en')
    expect(detectCoreLanguage(['fr'])).toBe('en')
  })

  it('formats dates with the device region', () => {
    const date = new Date(2026, 9, 5, 18, 7, 9).getTime()
    setCoreRegion('US')
    expect(formatDate(date, 'ddMMyyyy', 'en')).toBe('10/05/2026')
    expect(formatDate(date, 'jmm', 'en')).toMatch(/^6:07\sPM$/)
    setCoreRegion('GB')
    expect(formatDate(date, 'ddMMyyyy', 'en')).toBe('05/10/2026')
    expect(formatDate(date, 'jmm', 'en')).toBe('18:07')
    setCoreRegion('RU')
    expect(formatDate(date, 'ddMMyyyy jmmss', 'ru')).toBe('05.10.2026, 18:07:09')
    expect(formatDate(date, 'jmm', 'en')).toBe('18:07')
  })
})
