// Port of SyncTests.swift, plus the JSON shape Swift's Codable gives the messages.
import { describe, expect, it } from 'vitest'
import {
  PlanParser,
  SessionCommand,
  type SyncCommand,
  SyncHostInfo,
  SyncMessage,
  SyncState,
  TrainingSession,
} from '@core/index'

class Clock {
  now = 1_790_000_000_000
  advance(seconds: number) {
    this.now += seconds * 1000
  }
}

const plan = () =>
  PlanParser.parse(`Тренировка на воскресенье - Таня/Андрей - 04.10.2026
Все перерывы 2 минуты
1 выход - 10 секунд
2 выход - 30 секунд
Перерыв 5 минут
3 выход - 1 минута ИЛИ до вставания`)

/** Owner session in the middle of things: one exit done, a false start, behind the door now. */
function runningSession(clock: Clock): TrainingSession {
  const session = new TrainingSession(plan(), { clock: () => clock.now })
  session.startExit(); clock.advance(5); session.markBehindDoor(); clock.advance(11); session.endExit()
  clock.advance(121); session.startExit(); clock.advance(4); session.markBehindDoor(); clock.advance(8); session.resetExit()
  clock.advance(120); session.tick(); session.startExit(); clock.advance(6); session.markBehindDoor(); clock.advance(12)
  return session
}

describe('Sync', () => {
  it('snapshot survives JSON and rebuilds the same state', () => {
    const clock = new Clock()
    const owner = runningSession(clock)
    const message: SyncMessage = {
      kind: 'state',
      state: SyncState.make({
        session: owner.snapshot,
        recordingSince: owner.startedAt,
        cameraReady: true,
        cameraTitle: 'Прихожая',
        streamName: 'hall',
        lastRecord: null,
      }),
    }
    const decoded = SyncMessage.decode(SyncMessage.encode(message))
    if (decoded.kind !== 'state' || decoded.state.session === null) throw new Error('no state')
    const snapshot = decoded.state.session
    expect(snapshot).toEqual(owner.snapshot)

    const mirror = TrainingSession.fromSnapshot(snapshot, { clock: () => clock.now })
    expect(mirror.phase).toEqual(owner.phase)
    expect(mirror.attempt).toBe(2)
    expect(mirror.currentExit?.number).toBe(2)
    expect(mirror.remaining(clock.now)).toBe(owner.remaining(clock.now))
    expect(mirror.falseStartsCount).toBe(1)
    expect(mirror.events).toEqual(owner.events)
  })

  it('mirror forwards buttons and restores in place', () => {
    const clock = new Clock()
    const owner = runningSession(clock)
    const mirror = TrainingSession.fromSnapshot(owner.snapshot, { clock: () => clock.now })
    const sent: SessionCommand[] = []
    mirror.commandHandler = (command) => sent.push(command)

    mirror.endExit()
    expect(sent).toEqual(['endExit'])
    expect(mirror.phase.kind === 'leaving' || mirror.phase.kind === 'away', 'a mirror never changes on its own').toBe(true)

    // The owner applies the command and the mirror catches up from the next snapshot.
    sent.forEach((command) => SessionCommand.apply(command, owner))
    mirror.restore(owner.snapshot)
    expect(mirror.snapshot).toEqual(owner.snapshot)
    expect(mirror.phase.kind).toBe('breakTime')

    // Breaks end on the owner only.
    clock.advance(400)
    mirror.tick()
    expect(mirror.phase.kind, 'mirror must not tick').toBe('breakTime')
  })

  it('restore ignores another session', () => {
    const clock = new Clock()
    const a = runningSession(clock)
    const b = new TrainingSession(plan(), { clock: () => clock.now })
    const before = a.snapshot
    a.restore(b.snapshot)
    expect(a.snapshot).toEqual(before)
  })

  it('pending plan travels both ways', () => {
    const p = plan()
    const state: SyncMessage = {
      kind: 'state',
      state: SyncState.make({
        session: null,
        recordingSince: null,
        cameraReady: true,
        cameraTitle: 'Прихожая',
        streamName: 'hall',
        lastRecord: null,
        pendingPlan: p,
      }),
    }
    const decoded = SyncMessage.decode(SyncMessage.encode(state))
    if (decoded.kind !== 'state') throw new Error('no state')
    expect(decoded.state.pendingPlan).toEqual(p)

    const commands: SyncCommand[] = [
      { kind: 'setPendingPlan', plan: p },
      { kind: 'setPendingPlan', plan: null },
      { kind: 'updateSessionPlan', plan: p, quiet: null, since: null },
      { kind: 'updateSessionPlan', plan: p, quiet: true, since: null },
      { kind: 'updateSessionPlan', plan: p, quiet: null, since: p },
    ]
    for (const command of commands) {
      expect(SyncMessage.decode(SyncMessage.encode({ kind: 'command', command }))).toEqual({ kind: 'command', command })
    }
  })

  it('state without pending plan still decodes', () => {
    const old = SyncState.make({
      session: null,
      recordingSince: null,
      cameraReady: false,
      cameraTitle: '',
      streamName: '',
      lastRecord: null,
    })
    const json = JSON.parse(SyncMessage.encode({ kind: 'state', state: old }))
    const payload = json.state._0
    delete payload.pendingPlan
    json.state = { _0: payload }
    const decoded = SyncMessage.decode(JSON.stringify(json))
    if (decoded.kind !== 'state') throw new Error('no state')
    expect(decoded.state.pendingPlan).toBeNull()
  })

  it('host info TXT round trip', () => {
    const info = SyncHostInfo.make({
      name: 'MacBook Андрея',
      cameraTitle: 'Прихожая',
      cameraReady: true,
      sessionRunning: true,
      currentExit: 6,
    })
    expect(SyncHostInfo.fromTXT(info.name, SyncHostInfo.txt(info))).toEqual(info)
    expect(SyncHostInfo.txt(info)).toEqual({ v: '2', cam: 'Прихожая', ready: '1', session: '1', exit: '6' })
  })
})

// Not in the Swift suite: the exact JSON the Swift app reads and writes.
describe('SyncMessage JSON shape', () => {
  it('encodes enum cases like Swift Codable', () => {
    expect(SyncMessage.encode({ kind: 'pending' })).toBe('{"pending":{}}')
    expect(SyncMessage.encode({ kind: 'proof', proof: null })).toBe('{"proof":{}}')
    expect(SyncMessage.encode({ kind: 'proof', proof: new Uint8Array([1, 2, 3]) })).toBe('{"proof":{"_0":"AQID"}}')
    expect(SyncMessage.encode({ kind: 'rejected', reason: 'нет' })).toBe('{"rejected":{"_0":"нет"}}')
    expect(SyncMessage.encode({ kind: 'command', command: { kind: 'session', command: 'endExit' } })).toBe(
      '{"command":{"_0":{"session":{"_0":"endExit"}}}}',
    )
    expect(SyncMessage.encode({ kind: 'command', command: { kind: 'startRecording' } })).toBe(
      '{"command":{"_0":{"startRecording":{}}}}',
    )
    expect(
      JSON.parse(
        SyncMessage.encode({
          kind: 'hello',
          hello: { deviceID: 'id', deviceName: 'iPhone', publicKey: new Uint8Array(32).fill(255), protocolVersion: 2, platform: null, model: null },
        }),
      ),
    ).toEqual({
      hello: {
        _0: { deviceID: 'id', deviceName: 'iPhone', publicKey: '//////////////////////////////////////////8=', protocolVersion: 2 },
      },
    })
  })

  it('reads a state the Swift app sends (millisecond dates, phases as keyed cases)', () => {
    const frame = JSON.stringify({
      state: {
        _0: {
          cameraReady: true,
          cameraTitle: 'Прихожая',
          streamName: 'hall',
          recordingSince: 1790000000123.456,
          streamRevision: 3,
          session: {
            plan: {
              id: '9f5c6051-7e88-4344-8099-b15e6f708192',
              title: 'Тренировка',
              trainers: '',
              notes: [],
              defaultBreak: 120,
              exits: [{ id: '7D3A4E3F-5C66-4122-AE77-9F3C4D5E6F70', number: 1, duration: 5, untilStanding: false }],
              rawText: '',
            },
            startedAt: 1790000000000,
            phase: { breakTime: { afterExitIndex: 0, since: 1790000010000, duration: 120 } },
            events: [],
            results: [],
            attempt: 1,
            autoFinishAfterLastBreak: true,
            currentBreakStart: 1790000010000,
          },
        },
      },
    })
    const message = SyncMessage.decode(frame)
    if (message.kind !== 'state' || !message.state.session) throw new Error('no session')
    expect(message.state.recordingSince).toBe(1790000000123.456)
    expect(message.state.session.plan.id).toBe('9F5C6051-7E88-4344-8099-B15E6F708192')
    expect(message.state.session.phase).toEqual({
      kind: 'breakTime',
      afterExitIndex: 0,
      since: 1790000010000,
      duration: 120,
      nextExitIndex: null,
    })
    expect(message.state.session.finishedAt).toBeNull()
    expect(message.state.streamRevision).toBe(3)
    expect(message.state.cameraSource).toBeNull()
  })

  it('rejects frames with no or several cases', () => {
    expect(() => SyncMessage.decode('{}')).toThrow()
    expect(() => SyncMessage.decode('{"pending":{},"rejected":{"_0":"x"}}')).toThrow()
    expect(() => SyncMessage.decode('{"bogus":{}}')).toThrow(/unknown message/)
  })

  it('phases encode with Swift labels', () => {
    const snapshot = runningSession(new Clock()).snapshot
    const json = TrainingSession.encodeSnapshot(snapshot, 'millisecondsSince1970')
    expect(Object.keys(json.phase as object)).toEqual(['away'])
    expect(Object.keys((json.phase as Record<string, object>).away).sort()).toEqual(['exitIndex', 'leftAt', 'since'])
    expect('finishedAt' in json).toBe(false)
  })
})
