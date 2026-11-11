/// Updates of the Windows app installed from GitHub (electron-updater, src/main/updater.ts) — the Mac app's
/// `AppUpdater` (Sparkle) with the same modes, the same nightly switch and the same «Обновление» in the title bar.

/// Settings → About «Новые версии» (the Mac's `AppUpdater.Mode`).
export type UpdateMode = 'automatic' | 'notify' | 'manual'

export const UPDATE_MODES: UpdateMode[] = ['automatic', 'notify', 'manual']

/// A version waiting for the user: «Обновление» in the title bar and a row in Settings → About.
export interface PendingUpdate {
  version: string
  /// The release's first lines («что нового»), at most four.
  notes: string[]
  /// Downloaded: installs when the app quits, or at once with «Перезапустить». Otherwise only found.
  downloaded: boolean
  /// 0…100 while it downloads, null otherwise.
  progress: number | null
  /// «Загрузить и установить» was pressed: it installs as soon as it is downloaded and no training or recording runs.
  installing: boolean
  releasePage: string
}

export interface UpdatesState {
  /// Why this copy doesn't update itself: a development build ("dev"), or one run from the zip ("portable").
  unavailable: 'dev' | 'portable' | null
  checking: boolean
  /// Epoch ms of the last check that reached GitHub.
  lastCheck: number | null
  pending: PendingUpdate | null
  /// The last check or download failed (cleared by the next one that works).
  error: string | null
}

export const REPO_URL = 'https://github.com/AndrewAndreev/WaitingPaws'
export const RELEASES_PAGE = `${REPO_URL}/releases`
/// The feeds electron-updater reads `latest.yml` from: the Latest release, and the rolling «nightly» pre-release
/// (Tools/release.sh publish-nightly moves its tag, .github/workflows/windows.yml adds the Windows files).
export const STABLE_FEED = `${REPO_URL}/releases/latest/download`
export const NIGHTLY_FEED = `${REPO_URL}/releases/download/nightly`
/// A release's own folder: there electron-updater also finds the previous version's blockmap (`v1.7.20/…-1.7.20-…`)
/// and downloads only the changed blocks.
export function releaseFeed(version: string): string {
  return `${REPO_URL}/releases/download/v${version}`
}

/// Semantic versions: 1.7.21 > 1.7.21-nightly.2611111459 > 1.7.20. Negative, zero or positive; null for a version
/// that isn't X.Y.Z[-pre].
export function compareVersions(a: string, b: string): number | null {
  const left = parseVersion(a)
  const right = parseVersion(b)
  if (!left || !right) return null
  for (let index = 0; index < 3; index += 1) {
    if (left.core[index] !== right.core[index]) return left.core[index] - right.core[index]
  }
  // A version without a pre-release part is newer than the same one with it.
  if (!left.pre.length || !right.pre.length) return (left.pre.length ? -1 : 0) - (right.pre.length ? -1 : 0)
  for (let index = 0; index < Math.max(left.pre.length, right.pre.length); index += 1) {
    const x = left.pre[index]
    const y = right.pre[index]
    if (x === undefined) return -1
    if (y === undefined) return 1
    const xNumber = /^\d+$/.test(x)
    const yNumber = /^\d+$/.test(y)
    if (xNumber && yNumber) {
      if (Number(x) !== Number(y)) return Number(x) - Number(y)
    } else if (xNumber !== yNumber) {
      return xNumber ? -1 : 1
    } else if (x !== y) {
      return x < y ? -1 : 1
    }
  }
  return 0
}

function parseVersion(text: string): { core: number[]; pre: string[] } | null {
  const match = /^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$/.exec(text.trim())
  if (!match) return null
  return { core: [Number(match[1]), Number(match[2]), Number(match[3])], pre: match[4] ? match[4].split('.') : [] }
}

/// The version in a `latest.yml` (electron-builder's update info), or null.
export function feedVersion(yaml: string): string | null {
  const match = /^version:\s*['"]?([^'"\s]+)['"]?\s*$/m.exec(yaml)
  return match ? match[1] : null
}

/// The first lines of a release's description: markdown `- ` lines (Tools/release-notes/<version>.md, the nightly's
/// commit subjects) or HTML `<li>`s — the Mac's `UpdateNotes.lines`. electron-updater may also give a list of
/// `{ version, note }` (several versions' notes at once): the newest one's are taken.
export function updateNotes(description: unknown, limit = 4): string[] {
  let text: string | null = null
  if (typeof description === 'string') text = description
  else if (Array.isArray(description)) {
    const first = description.find((item) => item && typeof item === 'object' && typeof item.note === 'string')
    text = first ? first.note : null
  }
  if (!text) return []
  let items: string[]
  if (/<li/i.test(text)) {
    items = text
      .split(/<li/i)
      .slice(1)
      .map((part) => part.slice(part.indexOf('>') + 1).split(/<\/li/i)[0] ?? '')
  } else {
    items = text
      .split(/\r?\n/)
      .map((line) => line.trim())
      .flatMap((line) => {
        for (const marker of ['- ', '* ', '• ']) if (line.startsWith(marker)) return [line.slice(marker.length)]
        return []
      })
  }
  return items
    .map(plain)
    .filter((line) => line !== '')
    .slice(0, limit)
}

/// Tags and the common entities out, spaces folded.
function plain(html: string): string {
  let text = html.replace(/<[^>]+>/g, '')
  for (const [entity, char] of [
    ['&amp;', '&'],
    ['&lt;', '<'],
    ['&gt;', '>'],
    ['&quot;', '"'],
    ['&#39;', "'"],
    ['&nbsp;', ' '],
  ]) {
    text = text.split(entity).join(char)
  }
  return text.replace(/\s+/g, ' ').trim()
}
