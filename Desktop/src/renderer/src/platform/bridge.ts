import type { PlatformBridge } from '@shared/api'
import { createBrowserBridge } from './browserBackend'

/// In the desktop app `window.wp` comes from the preload script (Electron main is the backend). Opened in a plain
/// browser (the web build, or the dev server without Electron) the UI gets an in-page backend instead: the same
/// core (schedule parser, training engine, log) with history in the browser's storage and no camera.
export function installBridge(): void {
  if (typeof window.wp === 'undefined') {
    ;(window as unknown as { wp: PlatformBridge }).wp = createBrowserBridge()
  }
}

/// `fetch` for the core's Go2RTCClient: requests are made by the backend (no CORS, no browser Origin).
export const bridgeFetch: typeof fetch = async (input, init) => {
  const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url
  const headers: Record<string, string> = {}
  new Headers(init?.headers).forEach((value, key) => (headers[key] = value))
  let body: string | Uint8Array | undefined
  if (typeof init?.body === 'string') body = init.body
  else if (init?.body instanceof Uint8Array) body = init.body
  else if (init?.body instanceof ArrayBuffer) body = new Uint8Array(init.body)
  else if (init?.body instanceof URLSearchParams) body = init.body.toString()
  const response = await window.wp.call('go2rtc.fetch', { url, method: init?.method ?? 'GET', headers, body })
  return new Response(response.body.byteLength ? (response.body as Uint8Array<ArrayBuffer>) : null, {
    status: response.status,
    statusText: response.statusText,
    headers: response.headers,
  })
}
