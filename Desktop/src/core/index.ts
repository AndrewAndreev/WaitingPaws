// Waiting Paws core: a TypeScript port of the Swift package `Packages/WaitingPawsCore` (no UI, no Node APIs —
// it runs in the Electron main process, the renderer and a plain browser).
//
// Conventions
// -----------
// - Dates are epoch milliseconds (`number`), like `Date.now()`. Swift's `Date` maps to them; the JSON codecs
//   convert to Swift's encodings (ISO 8601 seconds on disk, milliseconds on the sync link).
// - Durations are seconds (`number`), like Swift's `TimeInterval`: `PlannedExit.duration`, breaks,
//   `TrainingSession.remaining(now)`…
// - Swift optionals are `T | null` in models (never `undefined`); the codecs leave nil keys out, as Swift does.
// - Models are plain immutable-by-convention objects; Swift members live in companion objects of the same name
//   (`TrainingPlan.breakAfter(plan, i)`, `PlannedExit.durationDescription(exit)`, `SessionEventKind.title(k)`).
// - Ids are UUID strings in Swift's upper-case `uuidString` form.
// - Texts are Russian or English by `coreLanguage()` (`setCoreLanguage('en')`), byte-identical to Swift's.
// - IO is injected: `StorageBackend` (files), `fetch` (go2rtc, miot-spec.org).
//
// Not here: `node/syncCrypto.ts` (X25519/HKDF/HMAC/ChaChaPoly on node:crypto, import it from
// '@core/node/syncCrypto' in the main process) and the Keychain (Electron safeStorage instead).

export * from './localization'
export * from './durationText'
export * from './models'
export * from './planParser'
export * from './sessionLog'
export * from './trainingSession'
export * from './sessionStore'
export * from './go2rtcClient'
export * from './streamRecorder'
export * from './cameraModes'
export * from './miotSpecProvider'
export * from './syncProtocol'
export {
  type DateEncoding,
  type JSONObject,
  type JSONValue,
  DISK_DATES,
  SYNC_DATES,
  DecodingError,
  base64Decode,
  base64Encode,
  deepEqual,
  formatISO8601,
  newUUID,
  parseISO8601,
  sameUUID,
  swiftJSONString,
} from './codable'
