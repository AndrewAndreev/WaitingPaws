import { createHash } from 'node:crypto'
import type { IncomingMessage } from 'node:http'
import type { Duplex } from 'node:stream'

/// The server side of RFC 6455, just what the iPhone link needs: the iPhone's `NWProtocolWebSocket` sends one
/// JSON message per text frame (the Mac app's `SyncChannel`). No extensions (no compression), no subprotocols;
/// fragmented messages, ping/pong and the close handshake are handled.

const acceptGUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'

const Opcode = { continuation: 0x0, text: 0x1, binary: 0x2, close: 0x8, ping: 0x9, pong: 0xa } as const

/// Close codes used here.
export const CloseCode = { normal: 1000, protocolError: 1002, invalidData: 1007, tooBig: 1009 } as const

/// `Sec-WebSocket-Accept` for a client's `Sec-WebSocket-Key`.
export function webSocketAccept(key: string): string {
  return createHash('sha1').update(key + acceptGUID).digest('base64')
}

/// Answers an HTTP upgrade request (`http.Server` 'upgrade' event). Returns the connection, not yet reading
/// (set the handlers, then `start(head)`), or null after refusing a request that is not a WebSocket handshake.
export function acceptWebSocket(request: IncomingMessage, socket: Duplex, options: { maxMessage?: number } = {}): WebSocketConnection | null {
  const key = request.headers['sec-websocket-key']
  const upgrade = String(request.headers.upgrade ?? '').toLowerCase()
  if (request.method !== 'GET' || upgrade !== 'websocket' || typeof key !== 'string' || key.trim() === '') {
    refuse(socket, '400 Bad Request')
    return null
  }
  if (request.headers['sec-websocket-version'] !== '13') {
    refuse(socket, '426 Upgrade Required', ['Sec-WebSocket-Version: 13'])
    return null
  }
  const connection = new WebSocketConnection(socket, options.maxMessage)
  socket.write(
    ['HTTP/1.1 101 Switching Protocols', 'Upgrade: websocket', 'Connection: Upgrade', `Sec-WebSocket-Accept: ${webSocketAccept(key.trim())}`, '', ''].join('\r\n'),
  )
  return connection
}

function refuse(socket: Duplex, status: string, headers: string[] = []): void {
  socket.on('error', () => undefined)
  try {
    socket.end([`HTTP/1.1 ${status}`, 'Connection: close', 'Content-Length: 0', ...headers, '', ''].join('\r\n'))
  } catch {
    socket.destroy()
  }
}

export class WebSocketConnection {
  /// A whole message (text or binary payload, fragments joined).
  onMessage: ((payload: Buffer, isText: boolean) => void) | null = null
  /// Called once, when the connection is gone for whatever reason.
  onClose: ((reason: string) => void) | null = null

  private buffer: Buffer = Buffer.alloc(0)
  private fragments: Buffer[] = []
  private fragmentsSize = 0
  private fragmentsText = false
  private reading = false
  private closing = false
  private finished = false

  constructor(
    readonly socket: Duplex,
    private readonly maxMessage = 8 * 1024 * 1024,
  ) {
    // Errors are reported through `onClose`, never thrown at the process.
    socket.on('error', (error: Error) => this.finish(error.message))
    socket.on('close', () => this.finish('closed'))
    // http.Server sockets allow half-open connections: the other side ended, so end ours too.
    socket.on('end', () => {
      this.closing = true
      socket.end()
    })
  }

  /// Starts reading; `head` is what arrived together with the upgrade request.
  start(head?: Buffer): void {
    if (this.reading) return
    this.reading = true
    this.socket.on('data', (chunk: Buffer) => this.feed(chunk))
    if (head && head.length > 0) this.feed(head)
  }

  get isOpen(): boolean {
    return !this.closing && !this.finished
  }

  /// Bytes written but not yet handed to the network (a reader that stopped reading makes this grow).
  get bufferedAmount(): number {
    return (this.socket as Duplex & { writableLength?: number }).writableLength ?? 0
  }

  sendText(text: string): boolean {
    return this.sendFrame(Opcode.text, Buffer.from(text, 'utf8'))
  }

  /// The close handshake: a close frame, then the socket ends (and is destroyed if the other side lingers).
  close(code: number = CloseCode.normal): void {
    if (this.finished) return
    if (!this.closing) {
      const payload = Buffer.alloc(2)
      payload.writeUInt16BE(code, 0)
      this.sendFrame(Opcode.close, payload)
      this.closing = true
    }
    try {
      this.socket.end()
    } catch {
      // Already gone.
    }
    setTimeout(() => this.socket.destroy(), 2000).unref()
  }

  /// Drops the connection without a close handshake.
  destroy(): void {
    this.closing = true
    this.socket.destroy()
  }

  private sendFrame(opcode: number, payload: Buffer): boolean {
    if (this.closing || this.finished) return false
    const length = payload.length
    let header: Buffer
    if (length < 126) {
      header = Buffer.from([0x80 | opcode, length])
    } else if (length < 0x10000) {
      header = Buffer.alloc(4)
      header[0] = 0x80 | opcode
      header[1] = 126
      header.writeUInt16BE(length, 2)
    } else {
      header = Buffer.alloc(10)
      header[0] = 0x80 | opcode
      header[1] = 127
      header.writeUInt32BE(Math.floor(length / 0x1_0000_0000), 2)
      header.writeUInt32BE(length >>> 0, 6)
    }
    try {
      this.socket.write(Buffer.concat([header, payload]))
      return true
    } catch {
      return false
    }
  }

  private feed(chunk: Buffer): void {
    this.buffer = this.buffer.length === 0 ? chunk : Buffer.concat([this.buffer, chunk])
    while (!this.finished && !this.closing) {
      const buffer = this.buffer
      if (buffer.length < 2) return
      const fin = (buffer[0] & 0x80) !== 0
      const reserved = buffer[0] & 0x70
      const opcode = buffer[0] & 0x0f
      const masked = (buffer[1] & 0x80) !== 0
      let length = buffer[1] & 0x7f
      let offset = 2
      if (length === 126) {
        if (buffer.length < 4) return
        length = buffer.readUInt16BE(2)
        offset = 4
      } else if (length === 127) {
        if (buffer.length < 10) return
        const high = buffer.readUInt32BE(2)
        if (high > 0) return this.fail(CloseCode.tooBig, 'frame too big')
        length = buffer.readUInt32BE(6)
        offset = 10
      }
      // No extensions were agreed on, so the reserved bits must be clear.
      if (reserved !== 0) return this.fail(CloseCode.protocolError, 'reserved bits set')
      if (length > this.maxMessage) return this.fail(CloseCode.tooBig, 'frame too big')
      const maskOffset = offset
      if (masked) offset += 4
      if (buffer.length < offset + length) return
      const payload = Buffer.from(buffer.subarray(offset, offset + length))
      if (masked) {
        for (let i = 0; i < payload.length; i++) payload[i] ^= buffer[maskOffset + (i & 3)]
      }
      this.buffer = buffer.subarray(offset + length)
      this.frame(fin, opcode, payload)
    }
  }

  private frame(fin: boolean, opcode: number, payload: Buffer): void {
    if (opcode >= 0x8) {
      if (!fin || payload.length > 125) return this.fail(CloseCode.protocolError, 'bad control frame')
      switch (opcode) {
        case Opcode.close: {
          const code = payload.length >= 2 ? payload.readUInt16BE(0) : CloseCode.normal
          this.close(code >= 1000 && code < 5000 && code !== 1005 && code !== 1006 ? code : CloseCode.normal)
          return
        }
        case Opcode.ping:
          this.sendFrame(Opcode.pong, payload)
          return
        case Opcode.pong:
          return
        default:
          return this.fail(CloseCode.protocolError, `unknown opcode ${opcode}`)
      }
    }
    if (opcode === Opcode.continuation) {
      if (this.fragments.length === 0) return this.fail(CloseCode.protocolError, 'continuation without a message')
    } else if (opcode === Opcode.text || opcode === Opcode.binary) {
      if (this.fragments.length > 0) return this.fail(CloseCode.protocolError, 'new message inside a fragmented one')
      this.fragmentsText = opcode === Opcode.text
    } else {
      return this.fail(CloseCode.protocolError, `unknown opcode ${opcode}`)
    }
    this.fragments.push(payload)
    this.fragmentsSize += payload.length
    if (this.fragmentsSize > this.maxMessage) return this.fail(CloseCode.tooBig, 'message too big')
    if (!fin) return
    const message = this.fragments.length === 1 ? this.fragments[0] : Buffer.concat(this.fragments)
    const isText = this.fragmentsText
    this.fragments = []
    this.fragmentsSize = 0
    this.onMessage?.(message, isText)
  }

  private fail(code: number, reason: string): void {
    this.close(code)
    this.finish(reason)
  }

  private finish(reason: string): void {
    if (this.finished) return
    this.finished = true
    this.closing = true
    const handler = this.onClose
    this.onClose = null
    this.onMessage = null
    handler?.(reason)
  }
}
