import { SyncMessage } from '@core/syncProtocol'
import type { SyncCipher } from '@core/node/syncCrypto'
import type { WebSocketConnection } from './websocket'

/// One JSON `SyncMessage` per WebSocket text frame (the Mac app's `SyncChannel`). Once the key exchange set `cipher`,
/// welcome / state / command messages go sealed; they are never sent or accepted in the clear, and a frame that does
/// not open closes the connection.
export class SyncChannel {
  onMessage: ((message: SyncMessage) => void) | null = null
  onClose: ((reason: string) => void) | null = null
  cipher: SyncCipher | null = null

  private static readonly utf8 = new TextDecoder('utf-8', { fatal: true })

  constructor(
    readonly connection: WebSocketConnection,
    private readonly log: (line: string) => void,
  ) {
    connection.onMessage = (payload) => this.receive(payload)
    connection.onClose = (reason) => this.onClose?.(reason)
  }

  /// The other side's IPv4 address ("192.168.1.20"), null for IPv6.
  get remoteIPv4(): string | null {
    return ipv4Only((this.connection.socket as { remoteAddress?: string }).remoteAddress)
  }

  /// This computer's address the other side connected to, null for IPv6.
  get localIPv4(): string | null {
    return ipv4Only((this.connection.socket as { localAddress?: string }).localAddress)
  }

  send(message: SyncMessage): void {
    let wire = message
    if (SyncMessage.needsSealing(message)) {
      if (!this.cipher) {
        this.log(`[sync] not sent: no key yet (${message.kind})`)
        return
      }
      wire = { kind: 'sealed', data: this.cipher.seal(message) }
    }
    this.connection.sendText(SyncMessage.encode(wire))
  }

  /// Closes the connection (close frame, then the socket).
  cancel(): void {
    this.connection.close()
  }

  private receive(payload: Buffer): void {
    let message: SyncMessage | null
    try {
      message = this.open(SyncMessage.decode(SyncChannel.utf8.decode(payload)))
    } catch (error) {
      this.log(`[sync] bad message, closing: ${(error as Error).message}`)
      this.connection.destroy()
      return
    }
    if (!message) return
    try {
      this.onMessage?.(message)
    } catch (error) {
      this.log(`[sync] handling ${message.kind} failed: ${(error as Error).stack ?? error}`)
    }
  }

  /// What the frame carries for the app; throws for a frame that must close the connection.
  private open(message: SyncMessage): SyncMessage | null {
    if (message.kind === 'sealed') {
      if (!this.cipher) throw new Error('sealed message before the key exchange')
      const inner = this.cipher.open(message.data)
      return SyncMessage.needsSealing(inner) ? inner : null
    }
    // Never in the clear: someone on the network is trying to skip the key exchange.
    if (SyncMessage.needsSealing(message)) throw new Error(`${message.kind} in the clear`)
    return message
  }
}

function ipv4Only(address: string | undefined): string | null {
  if (!address) return null
  const plain = address.startsWith('::ffff:') ? address.slice(7) : address
  return /^\d{1,3}(\.\d{1,3}){3}$/.test(plain) ? plain : null
}
