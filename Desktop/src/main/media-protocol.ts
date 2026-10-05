import { protocol } from 'electron'
import { createReadStream, statSync } from 'node:fs'
import { extname, join, normalize, sep } from 'node:path'
import { Readable } from 'node:stream'

/// `wp-media://recordings/<file>` — the user's recordings for the history player and thumbnails, with HTTP
/// range support so the <video> element can seek. Only files inside the allowed roots are served.
/// A web build would serve the same paths over HTTP.
export const MEDIA_SCHEME = 'wp-media'

export function registerMediaScheme(): void {
  protocol.registerSchemesAsPrivileged([
    { scheme: MEDIA_SCHEME, privileges: { standard: true, secure: true, stream: true, supportFetchAPI: true, bypassCSP: true, corsEnabled: true } },
  ])
}

const types: Record<string, string> = {
  '.mp4': 'video/mp4',
  '.m4a': 'audio/mp4',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.png': 'image/png',
  '.txt': 'text/plain; charset=utf-8',
  '.json': 'application/json',
}

export function handleMediaScheme(roots: () => Record<string, string>): void {
  protocol.handle(MEDIA_SCHEME, (request) => {
    const url = new URL(request.url)
    const root = roots()[url.hostname]
    if (!root) return new Response('not found', { status: 404 })
    const relative = decodeURIComponent(url.pathname).replace(/^\/+/, '')
    const path = normalize(join(root, relative))
    if (!path.startsWith(normalize(root) + sep)) return new Response('forbidden', { status: 403 })
    let size: number
    try {
      size = statSync(path).size
    } catch {
      return new Response('not found', { status: 404 })
    }
    const type = types[extname(path).toLowerCase()] ?? 'application/octet-stream'
    const range = request.headers.get('range')
    const match = range ? /bytes=(\d*)-(\d*)/.exec(range) : null
    if (match && size > 0) {
      let start = match[1] ? Number(match[1]) : 0
      let end = match[2] ? Number(match[2]) : size - 1
      if (!match[1] && match[2]) {
        start = Math.max(0, size - Number(match[2]))
        end = size - 1
      }
      end = Math.min(end, size - 1)
      if (start > end || start >= size) {
        return new Response(null, { status: 416, headers: { 'Content-Range': `bytes */${size}` } })
      }
      const stream = Readable.toWeb(createReadStream(path, { start, end })) as ReadableStream
      return new Response(stream, {
        status: 206,
        headers: {
          'Access-Control-Allow-Origin': '*',
          'Content-Type': type,
          'Content-Length': String(end - start + 1),
          'Content-Range': `bytes ${start}-${end}/${size}`,
          'Accept-Ranges': 'bytes',
          'Cache-Control': 'no-cache',
        },
      })
    }
    const stream = Readable.toWeb(createReadStream(path)) as ReadableStream
    return new Response(stream, {
      status: 200,
      headers: { 'Access-Control-Allow-Origin': '*', 'Content-Type': type, 'Content-Length': String(size), 'Accept-Ranges': 'bytes', 'Cache-Control': 'no-cache' },
    })
  })
}

export function mediaURL(root: string, fileName: string): string {
  return `${MEDIA_SCHEME}://${root}/${encodeURIComponent(fileName)}`
}
