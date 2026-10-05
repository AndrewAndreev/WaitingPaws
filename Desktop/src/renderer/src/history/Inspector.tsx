import { useCallback, useEffect, useRef, useState, type PointerEvent, type ReactNode } from 'react'
import { t } from '@shared/i18n'
import { DurationText } from '@core/durationText'
import { SessionLogFormatter, type ExitResult, type TrainingRecord } from '@core/sessionLog'
import { call, ui, useStore } from '../store'
import { formatTime } from '../model'
import { formatBytes } from '../format'
import {
  CheckIcon,
  ChevronDownIcon,
  CopyFileIcon,
  CopyIcon,
  DeleteIcon,
  DoneCircleIcon,
  FalseStartFilledIcon,
  FolderIcon,
  InspectorIcon,
  PlayFilledIcon,
  VideoOffIcon,
} from '../ui/icons'
import { Button, Menu, MenuContent, MenuItem, MenuTrigger, Spinner, Tooltip } from '../ui/kit'
import {
  awayText,
  breakIsOff,
  completedExits,
  exitOffset,
  falseStarts,
  keyOf,
  longestPlanned,
  longestStay,
  recordDuration,
  recordingStart,
  stripSegments,
  stripTicks,
  type HistoryRow,
  type StripSegment,
} from './logic'
import { longDay } from './format'
import { useMedia, videoURL } from './media'
import { historyUI, player, useHistoryUI, usePlayer } from './state'
import type { RowActions } from './HistoryTable'
import { useDelayed } from './useDelayed'
import { useSize } from './useSize'

/// Details pane of the selected row (MacHistoryInspector): video with the exit strip, totals, the per-exit log
/// for the trainer, the file and delete.
export function Inspector({ row, preparing, actions }: { row: HistoryRow | null; preparing: boolean; actions: RowActions }) {
  if (!row) {
    return (
      <div className="empty-state hinspector__empty">
        <InspectorIcon style={{ width: 32, height: 32 }} />
        <div className="empty-state__title">{t('Ничего не выбрано')}</div>
        <div>{t('Выберите тренировку или запись в таблице.')}</div>
      </div>
    )
  }
  const record = row.record
  return (
    <div className="hinspector__content">
      <div className="hinspector__top">
        {row.video ? <VideoPlayer fileName={row.video.fileName} exists={row.video.exists} preparing={preparing} /> : <NoVideo record={record} />}
        {record && <Strip row={row} record={record} />}
        <div className="hinspector__heading">
          <div className="hinspector__title selectable">{row.title}</div>
          <div className="muted tabular">{longDay(row)}</div>
        </div>
      </div>
      {record && (
        <Section id="summary" title={t('Итоги')}>
          <Totals record={record} />
        </Section>
      )}
      {record && (
        <Section id="log" title={t('Лог')}>
          <ExitLog row={row} record={record} actions={actions} />
        </Section>
      )}
      <Section id="video" title={t('Видео')}>
        <VideoInfoSection row={row} preparing={preparing} actions={actions} />
      </Section>
      <div className="hinspector__footer">
        <DeleteButton row={row} actions={actions} />
      </div>
    </div>
  )
}

// MARK: - Video

/// Recordings are finalized once after stopping (or on first open, for older ones): the player waits for that and
/// loads the new file when it is done.
const finalizeChecked = new Set<string>()

function VideoPlayer({ fileName, exists, preparing }: { fileName: string; exists: boolean | null; preparing: boolean }) {
  const element = useRef<HTMLVideoElement | null>(null)
  const version = useMedia((store) => store.generations[fileName] ?? 0)
  const [checked, setChecked] = useState(() => finalizeChecked.has(fileName))
  const [failed, setFailed] = useState(false)
  const loaded = usePlayer((state) => state.loaded === fileName)
  const seekRequest = useStore((store) => store.historySeek)

  // Once the file is known to be there: finalize it if it never was (cheap when it was).
  useEffect(() => {
    if (finalizeChecked.has(fileName)) {
      setChecked(true)
      return
    }
    setChecked(false)
    if (exists !== true) return
    let cancelled = false
    void call('history.finalize', fileName).finally(() => {
      finalizeChecked.add(fileName)
      if (!cancelled) setChecked(true)
    })
    return () => {
      cancelled = true
    }
  }, [fileName, exists])

  useEffect(() => setFailed(false), [fileName, version])

  // Seek requests from elsewhere (`historySeek`), once the file is ready; each is used once.
  useEffect(() => {
    if (!seekRequest || !loaded) return
    player.seek(seekRequest.time)
    ui.set({ historySeek: null })
  }, [seekRequest?.token, loaded]) // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => () => usePlayer.setState({ element: null, loaded: null, time: 0, playing: false }), [])

  // A new element (another file, or the same one rewritten) is not loaded until it says so.
  const attach = useCallback((node: HTMLVideoElement | null) => {
    element.current = node
    if (node) usePlayer.setState({ element: node, loaded: null, time: 0, playing: false })
  }, [])

  const ready = checked && !preparing
  const src = ready ? videoURL(fileName, version) : undefined
  const waiting = useDelayed(!ready || (!loaded && !failed))
  return (
    <div className="hplayer">
      {src && (
        <video
          key={src}
          ref={attach}
          className="hplayer__video"
          src={src}
          controls
          preload="metadata"
          controlsList="nodownload noremoteplayback"
          disablePictureInPicture
          onLoadedMetadata={(event) => {
            usePlayer.setState({ element: event.currentTarget, loaded: fileName, time: event.currentTarget.currentTime })
            if (usePlayer.getState().playWhenLoaded === fileName) player.play(fileName)
          }}
          onTimeUpdate={(event) => usePlayer.setState({ time: event.currentTarget.currentTime })}
          onSeeking={(event) => usePlayer.setState({ time: event.currentTarget.currentTime })}
          onPlay={() => usePlayer.setState({ playing: true })}
          onPause={() => usePlayer.setState({ playing: false })}
          onEnded={() => usePlayer.setState({ playing: false })}
          onError={() => setFailed(true)}
        />
      )}
      {(waiting || failed) && (
        <div className="hplayer__status">
          {failed ? (
            <span>{t('Не удалось открыть видео')}</span>
          ) : (
            <>
              <Spinner />
              <span>{preparing ? t('Готовим видео…') : t('Открываем видео…')}</span>
            </>
          )}
        </div>
      )}
    </div>
  )
}

function NoVideo({ record }: { record: TrainingRecord | null }) {
  return (
    <div className="hnovideo">
      <VideoOffIcon />
      <div>
        <div>{t('Видео нет')}</div>
        <div className="faint" style={{ fontSize: 12 }}>
          {record?.recordingFileName ? t('Файл видео удалён') : t('Запись не включали')}
        </div>
      </div>
    </div>
  )
}

// MARK: - Exit strip

/// The training laid along its recording (MacHistoryExitStrip): walks to the door, time behind it (numbered),
/// false starts, breaks. The bar follows the video; a click on an exit jumps to it, a click or drag on the track
/// seeks.
function Strip({ row, record }: { row: HistoryRow; record: TrainingRecord }) {
  const video = row.video
  const loaded = usePlayer((state) => (video ? state.loaded === video.fileName : false))
  const time = usePlayer((state) => state.time)
  const [size, ref] = useSize<HTMLDivElement>()
  const base = video ? recordingStart(record) : record.startedAt
  const total = video ? video.duration ?? (record.finishedAt - base) / 1000 : recordDuration(record)
  const segments = stripSegments(record, base, total)
  const width = size.width
  const x = (offset: number) => width * Math.min(1, Math.max(0, offset / Math.max(1, total)))
  const ticks = stripTicks(base, total, width)
  const canSeek = loaded

  const seekTo = (event: PointerEvent<HTMLDivElement>) => {
    if (!canSeek || width <= 0) return
    const box = event.currentTarget.getBoundingClientRect()
    player.seek(total * Math.min(1, Math.max(0, (event.clientX - box.left) / box.width)))
  }

  return (
    <div className="hstrip" ref={ref} aria-label={t('Выходы по времени')}>
      <div className="hstrip__markers">
        {width > 0 &&
          segments
            .filter((segment) => segment.kind === 'away' || segment.kind === 'falseStart')
            .map((segment) => <Marker key={segment.id} segment={segment} left={Math.min(Math.max(7, x((segment.start + segment.end) / 2)), width - 7)} canSeek={canSeek} />)}
      </div>
      <div
        className={'hstrip__track' + (canSeek ? ' hstrip__track--seekable' : '')}
        onPointerDown={(event) => {
          if (!canSeek) return
          event.currentTarget.setPointerCapture(event.pointerId)
          seekTo(event)
        }}
        onPointerMove={(event) => {
          if (event.buttons & 1 && event.currentTarget.hasPointerCapture(event.pointerId)) seekTo(event)
        }}
      >
        <div className="hstrip__rail">
          {width > 0 &&
            segments.map((segment) => (
              <span
                key={segment.id}
                className={'hstrip__seg hstrip__seg--' + segment.kind}
                style={{ left: x(segment.start), width: Math.max(segment.kind === 'rest' ? 1 : 2.5, x(segment.end) - x(segment.start)) }}
              />
            ))}
        </div>
        {canSeek && width > 0 && <span className="hstrip__playhead" style={{ left: x(time) }} />}
      </div>
      <div className="hstrip__ticks">
        {ticks.map((offset) => (
          <span key={offset} className="hstrip__tick tabular" style={{ left: Math.min(Math.max(14, x(offset)), width - 14) }}>
            {formatTime(base + offset * 1000)}
          </span>
        ))}
      </div>
    </div>
  )
}

function Marker({ segment, left, canSeek }: { segment: StripSegment; left: number; canSeek: boolean }) {
  const help = segment.kind === 'falseStart' ? t('Выход %lld: фальстарт', segment.exit) : t('Выход %lld', segment.exit)
  return (
    <Tooltip content={canSeek ? t('%@. Нажмите, чтобы перейти к этому выходу в видео.', help) : help} side="top">
      <button
        type="button"
        tabIndex={-1}
        className={'hstrip__marker' + (segment.kind === 'falseStart' ? ' hstrip__marker--false' : '')}
        style={{ left }}
        disabled={!canSeek}
        aria-label={help}
        onClick={() => player.seek(segment.jump)}
      >
        {segment.kind === 'falseStart' ? <FalseStartFilledIcon /> : segment.exit}
      </button>
    </Tooltip>
  )
}

// MARK: - Sections

function Section({ id, title, children }: { id: string; title: string; children: ReactNode }) {
  const collapsed = useHistoryUI((store) => store.collapsed.includes(id))
  return (
    <section className="hsection">
      <button
        type="button"
        className="hsection__header"
        aria-expanded={!collapsed}
        onClick={() => {
          const list = historyUI.get().collapsed
          historyUI.set({ collapsed: collapsed ? list.filter((item) => item !== id) : [...list, id] })
        }}
      >
        <span className="section-title">{title}</span>
        <ChevronDownIcon className={'hsection__chevron' + (collapsed ? ' hsection__chevron--collapsed' : '')} />
      </button>
      {!collapsed && <div className="hsection__body">{children}</div>}
    </section>
  )
}

function Totals({ record }: { record: TrainingRecord }) {
  const count = falseStarts(record)
  return (
    <dl className="hfacts">
      {record.plan.trainers && <Fact label={t('Тренеры')} value={record.plan.trainers} />}
      <Fact label={t('Выходы')} value={t('%lld из %lld по плану', completedExits(record), record.plan.exits.length)} />
      <Fact label={t('Фальстарты')} value={<span style={count ? { color: 'var(--warning)' } : undefined}>{count === 0 ? t('нет') : String(count)}</span>} />
      <Fact
        label={t('Дольше всего')}
        value={
          <>
            <strong>{DurationText.clock(longestStay(record))}</strong>
            <span className="muted">{'  ' + t('план %@', DurationText.clock(longestPlanned(record)))}</span>
          </>
        }
      />
      <Fact label={t('Длительность')} value={DurationText.clock(recordDuration(record))} />
    </dl>
  )
}

function Fact({ label, value }: { label: string; value: ReactNode }) {
  return (
    <>
      <dt>{label}</dt>
      <dd className="tabular selectable">{value}</dd>
    </>
  )
}

/// Planned vs actual, one row per attempt (MacHistoryExitLog); with a video a click jumps to that exit.
function ExitLog({ row, record, actions }: { row: HistoryRow; record: TrainingRecord; actions: RowActions }) {
  const loaded = usePlayer((state) => (row.video ? state.loaded === row.video.fileName : false))
  const copied = useHistoryUI((store) => store.copiedKey === keyOf(row))
  const notes = record.events.filter((event) => event.kind === 'note' && (event.detail ?? '') !== '')
  return (
    <div className="col" style={{ gap: 0 }}>
      <div className="hlog" role="table" aria-label={t('Лог')}>
        <div className="hlog__row hlog__row--header" role="row">
          <span role="columnheader">№</span>
          <span role="columnheader" className="hlog__num">
            {t('План')}
          </span>
          <span role="columnheader" className="hlog__num">
            {t('Факт')}
          </span>
          <span role="columnheader" />
          <span role="columnheader" className="hlog__num">
            {t('Перерыв')}
          </span>
          <span role="columnheader" className="hlog__num">
            {t('план')}
          </span>
          <span role="columnheader" />
        </div>
        {record.results.map((result, index) => (
          <ExitLine key={result.id} record={record} result={result} isLast={index === record.results.length - 1} canJump={loaded} />
        ))}
      </div>
      {notes.length > 0 && (
        <div className="hnotes">
          {notes.map((note) => {
            const time = formatTime(note.time)
            return (
              <div key={note.id} className="selectable">
                <span className="muted">{note.exitNumber !== null ? t('%@, выход %lld', time, note.exitNumber) : time}</span> {note.detail}
              </div>
            )
          })}
        </div>
      )}
      <div className="row" style={{ marginTop: 12 }}>
        <Tooltip content={t('Скопировать лог для тренера') + ' (Ctrl+Shift+C)'}>
          <Button size="sm" icon={copied ? <CheckIcon /> : <CopyIcon />} shortcut={copied ? undefined : 'Ctrl+Shift+C'} onClick={() => actions.copyLog(row)}>
            {copied ? t('Скопировано') : t('Скопировать')}
          </Button>
        </Tooltip>
      </div>
    </div>
  )
}

function ExitLine({ record, result, isLast, canJump }: { record: TrainingRecord; result: ExitResult; isLast: boolean; canJump: boolean }) {
  const rest = isLast ? null : result.actualBreak
  const off = rest !== null && breakIsOff(result)
  const away = awayText(result, DurationText.clock)
  const parts = [result.attempt > 1 ? t('Выход %lld, попытка %lld', result.number, result.attempt) : t('Выход %lld', result.number), SessionLogFormatter.outcome(result)]
  if (result.untilStanding) parts.push(t('* план: или до вставания'))
  const help = parts.join(', ')
  return (
    <Tooltip content={canJump ? t('%@. Нажмите, чтобы перейти к этому выходу в видео.', help) : help} side="left">
      <div
        role="row"
        className={'hlog__row' + (canJump ? ' hlog__row--jump' : '')}
        onClick={() => {
          if (canJump) player.seek(exitOffset(record, result))
        }}
      >
        <span className="muted">{result.attempt > 1 ? `${result.number}·${result.attempt}` : result.number}</span>
        <span className="hlog__num muted">{DurationText.clock(result.plannedDuration) + (result.untilStanding ? '*' : '')}</span>
        <span className={'hlog__num hlog__actual' + (result.falseStart ? ' hlog__actual--false' : '')}>{away ?? '—'}</span>
        <span className={'hlog__status' + (result.falseStart ? ' hlog__status--false' : '')}>{result.falseStart ? <FalseStartFilledIcon /> : <DoneCircleIcon />}</span>
        <span className={'hlog__num' + (off ? ' hlog__off' : rest === null ? ' faint' : '')}>{rest === null ? '—' : DurationText.clock(rest)}</span>
        <span className="hlog__num faint">{rest === null ? '' : DurationText.clock(result.plannedBreak)}</span>
        <span className="hlog__jump">{canJump && <PlayFilledIcon />}</span>
      </div>
    </Tooltip>
  )
}

function VideoInfoSection({ row, preparing, actions }: { row: HistoryRow; preparing: boolean; actions: RowActions }) {
  const delayed = useDelayed(preparing)
  const video = row.video
  if (!video) {
    return (
      <div className="col" style={{ gap: 8, alignItems: 'flex-start' }}>
        <span className="muted">{t('От этой тренировки остался только лог.')}</span>
        {row.record && (
          <Button size="sm" icon={<FolderIcon />} onClick={() => actions.reveal(row)}>
            {t('Показать лог в проводнике')}
          </Button>
        )}
      </div>
    )
  }
  return (
    <div className="col" style={{ gap: 10 }}>
      <dl className="hfacts">
        <Fact label={t('Файл')} value={<span className="hfacts__file" title={video.fileName}>{video.fileName}</span>} />
        <Fact label={t('Длина')} value={video.duration !== null ? DurationText.clock(video.duration) : '—'} />
        <Fact label={t('Размер')} value={preparing ? t('готовится…') : video.bytes ? formatBytes(video.bytes) : '—'} />
      </dl>
      <div className="row" style={{ flexWrap: 'wrap' }}>
        <Button size="sm" icon={<FolderIcon />} onClick={() => actions.reveal(row)}>
          {t('Показать в проводнике')}
        </Button>
        <Tooltip content={t('Файл попадёт в буфер обмена — вставьте его в мессенджер или папку')}>
          <Button size="sm" icon={<CopyFileIcon />} disabled={preparing} onClick={() => actions.copyFile(row)}>
            {t('Копировать файл')}
          </Button>
        </Tooltip>
      </div>
      {delayed && (
        <div className="row muted" style={{ fontSize: 13 }}>
          <Spinner />
          {t('Готовим видео для отправки…')}
        </div>
      )}
    </div>
  )
}

function DeleteButton({ row, actions }: { row: HistoryRow; actions: RowActions }) {
  if (row.kind === 'record' && row.video) {
    return (
      <Menu>
        <MenuTrigger asChild>
          <button type="button" className="btn btn--sm btn--danger">
            <DeleteIcon />
            <span>{t('Удалить…')}</span>
            <ChevronDownIcon />
          </button>
        </MenuTrigger>
        <MenuContent>
          <MenuItem icon={<DeleteIcon />} danger onSelect={() => actions.confirmDelete(row, false)}>
            {t('Удалить тренировку и видео…')}
          </MenuItem>
          <MenuItem onSelect={() => actions.confirmDelete(row, true)}>{t('Удалить только лог, видео оставить…')}</MenuItem>
        </MenuContent>
      </Menu>
    )
  }
  return (
    <Button size="sm" variant="danger" icon={<DeleteIcon />} onClick={() => actions.confirmDelete(row, false)}>
      {row.kind === 'clip' ? t('Удалить запись…') : t('Удалить тренировку…')}
    </Button>
  )
}
