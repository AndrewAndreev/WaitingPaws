/// Keeps a local draft of the waiting plan in step with the backend while edits are in flight. Every local edit is
/// sent (`pending.set`) and shown at once; the states the backend pushes back are then one of:
/// - an echo of one of our edits (possibly several coalesced into the last one): keep the draft;
/// - the value from before our edits, pushed for some other reason before they arrived: keep the draft;
/// - anything else (a new paste, a linked iPhone, the other editor): replace the draft.
export class DraftSync {
  private sent: string[] = []
  private base: string

  constructor(initial: string) {
    this.base = initial
  }

  /// A local edit on its way to the backend.
  send(json: string): void {
    this.sent.push(json)
  }

  receive(json: string): 'keep' | 'replace' {
    const echo = this.sent.indexOf(json)
    if (echo >= 0) {
      this.sent = this.sent.slice(echo + 1)
      this.base = json
      return 'keep'
    }
    if (json === this.base) return 'keep'
    this.sent = []
    this.base = json
    return 'replace'
  }

  get pending(): number {
    return this.sent.length
  }
}
