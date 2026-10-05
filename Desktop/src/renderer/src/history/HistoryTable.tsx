import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type KeyboardEvent, type ReactNode } from 'react'
import { t } from '@shared/i18n'
import { DurationText } from '@core/durationText'
import { coreLocale } from '@core/localization'
import { formatTime } from '../model'
import { formatBytes } from '../format'
import {
  ClipIcon,
  CopyFileIcon,
  CopyIcon,
  DeleteIcon,
  FalseStartIcon,
  FolderIcon,
  PawFilledIcon,
  PlayIcon,
  SortAscendingIcon,
  SortDescendingIcon,
} from '../ui/icons'
import { ContextMenu, ContextMenuContent, ContextMenuItem, ContextMenuSeparator, ContextMenuTrigger, Spinner, Tooltip } from '../ui/kit'
import {
  completedExits,
  falseStarts,
  fitColumns,
  gridTemplate,
  keyOf,
  longestPlanned,
  longestStay,
  rowDuration,
  type ColumnSpec,
  type HistoryRow,
  type Sort,
  type SortKey,
} from './logic'
import { dayText } from './format'
import { useThumbnail } from './media'
import { useDelayed } from './useDelayed'
import { useSize } from './useSize'

interface Column extends ColumnSpec<SortKey> {
  label: string
  end?: boolean
}

/// Table columns (MacHistoryTable), least important hidden first when the page is narrow.
const COLUMNS: Column[] = [
  { key: 'date', label: 'Дата', width: 148, priority: 0 },
  { key: 'start', label: 'Начало', width: 62, priority: 6 },
  { key: 'title', label: 'Тренировка', min: 170, flex: 2, priority: 0 },
  { key: 'trainers', label: 'Тренеры', min: 96, flex: 1, priority: 5 },
  { key: 'exits', label: 'Выходы', width: 66, priority: 1 },
  { key: 'falseStarts', label: 'Фальстарты', width: 94, priority: 2 },
  { key: 'longest', label: 'Дольше всего', width: 122, priority: 0 },
  { key: 'plan', label: 'План', width: 56, priority: 3 },
  { key: 'duration', label: 'Длительность', width: 98, priority: 2, end: true },
  { key: 'video', label: 'Видео', width: 72, priority: 3, end: true },
]

/// "6:36 PM" needs a wider start column than "18:36".
function columnsForClock(): Column[] {
  const h12 = new Intl.DateTimeFormat(coreLocale(), { hour: 'numeric' }).resolvedOptions().hourCycle === 'h12'
  return h12 ? COLUMNS.map((column) => (column.key === 'start' ? { ...column, width: 82 } : column)) : COLUMNS
}

/// Horizontal padding of the table (both sides) and of the rows' highlight.
const INSET = 12

export interface RowActions {
  select(row: HistoryRow): void
  /// Double click / Enter: play the video, or show the inspector for a training without one.
  activate(row: HistoryRow): void
  togglePlayback(row: HistoryRow): void
  play(row: HistoryRow): void
  reveal(row: HistoryRow): void
  copyFile(row: HistoryRow): void
  copyLog(row: HistoryRow): void
  confirmDelete(row: HistoryRow, onlyLog: boolean | null): void
}

export function HistoryTable({
  rows,
  selectedKey,
  sort,
  onSort,
  longestEver,
  finalizing,
  scrollRequest,
  actions,
  empty,
}: {
  rows: HistoryRow[]
  selectedKey: string | null
  sort: Sort
  onSort: (key: SortKey) => void
  longestEver: number
  finalizing: ReadonlySet<string>
  scrollRequest: number
  actions: RowActions
  empty: ReactNode
}) {
  const [size, sizeRef] = useSize<HTMLDivElement>()
  const scroller = useRef<HTMLDivElement | null>(null)
  const all = useMemo(() => columnsForClock(), [])
  const columns = size.width > 0 ? fitColumns(all, size.width - INSET * 2 - 2) : all
  const template = gridTemplate(columns)
  const selectedIndex = rows.findIndex((row) => keyOf(row) === selectedKey)

  // Bring the selection into view when asked from outside (the chart, another page).
  useEffect(() => {
    if (scrollRequest === 0) return
    const element = scroller.current?.querySelector<HTMLElement>(`[data-key="${CSS.escape(selectedKey ?? '')}"]`)
    element?.scrollIntoView({ block: 'center' })
  }, [scrollRequest]) // eslint-disable-line react-hooks/exhaustive-deps

  const move = (index: number) => {
    const row = rows[Math.max(0, Math.min(rows.length - 1, index))]
    if (!row) return
    actions.select(row)
    requestAnimationFrame(() => scroller.current?.querySelector<HTMLElement>(`[data-key="${CSS.escape(keyOf(row))}"]`)?.scrollIntoView({ block: 'nearest' }))
  }

  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (event.target !== event.currentTarget) return
    const selected = rows[selectedIndex]
    const page = Math.max(1, Math.floor((scroller.current?.clientHeight ?? 360) / 36) - 2)
    switch (event.key) {
      case 'ArrowDown':
        event.preventDefault()
        return move(selectedIndex < 0 ? 0 : selectedIndex + 1)
      case 'ArrowUp':
        event.preventDefault()
        return move(selectedIndex < 0 ? 0 : selectedIndex - 1)
      case 'PageDown':
        event.preventDefault()
        return move(selectedIndex + page)
      case 'PageUp':
        event.preventDefault()
        return move(selectedIndex - page)
      case 'Home':
        event.preventDefault()
        return move(0)
      case 'End':
        event.preventDefault()
        return move(rows.length - 1)
      case 'Enter':
        if (selected) {
          event.preventDefault()
          actions.activate(selected)
        }
        return
      case ' ':
        if (selected?.video) {
          event.preventDefault()
          if (!event.repeat) actions.togglePlayback(selected)
        }
        return
      case 'Delete':
        if (selected) {
          event.preventDefault()
          actions.confirmDelete(selected, null)
        }
        return
      case 'c':
      case 'C':
        // Ctrl+C on a training copies its log.
        if ((event.ctrlKey || event.metaKey) && selected?.record) {
          event.preventDefault()
          actions.copyLog(selected)
        }
        return
    }
  }

  return (
    <div
      className="htable"
      ref={(element) => {
        scroller.current = element
        sizeRef(element)
      }}
      role="grid"
      aria-rowcount={rows.length}
      aria-label={t('История')}
      tabIndex={0}
      onKeyDown={onKeyDown}
      style={{ ['--hcols' as string]: template }}
    >
      <div className="hrow hrow--header" role="row">
        {columns.map((column) => {
          const active = sort.key === column.key
          return (
            <button
              key={column.key}
              type="button"
              role="columnheader"
              tabIndex={-1}
              aria-sort={active ? (sort.descending ? 'descending' : 'ascending') : 'none'}
              className={'hcell hcell--header' + (column.end ? ' hcell--end' : '') + (active ? ' hcell--sorted' : '')}
              onMouseDown={(event) => event.preventDefault()}
              onClick={() => onSort(column.key)}
            >
              <span className="ellipsis">{t(column.label)}</span>
              {active && (sort.descending ? <SortDescendingIcon className="hsort" /> : <SortAscendingIcon className="hsort" />)}
            </button>
          )
        })}
      </div>
      {rows.length === 0
        ? empty
        : rows.map((row) => (
            <Row
              key={keyOf(row)}
              row={row}
              columns={columns}
              selected={keyOf(row) === selectedKey}
              preparing={row.video ? finalizing.has(row.video.fileName) : false}
              longestEver={longestEver}
              actions={actions}
            />
          ))}
    </div>
  )
}

function Row({ row, columns, selected, preparing, longestEver, actions }: { row: HistoryRow; columns: Column[]; selected: boolean; preparing: boolean; longestEver: number; actions: RowActions }) {
  return (
    <ContextMenu>
      <ContextMenuTrigger asChild>
        <div
          className={'hrow' + (selected ? ' hrow--selected' : '') + (row.kind === 'clip' ? ' hrow--clip' : '')}
          role="row"
          aria-selected={selected}
          data-key={keyOf(row)}
          onMouseDown={(event) => {
            if (event.button === 0 || event.button === 2) actions.select(row)
          }}
          onDoubleClick={() => actions.activate(row)}
        >
          {columns.map((column) => (
            <div key={column.key} role="gridcell" className={'hcell' + (column.end ? ' hcell--end' : '')}>
              <Cell row={row} column={column.key} preparing={preparing} longestEver={longestEver} />
            </div>
          ))}
        </div>
      </ContextMenuTrigger>
      <ContextMenuContent>
        <RowMenu row={row} preparing={preparing} actions={actions} />
      </ContextMenuContent>
    </ContextMenu>
  )
}

/// Context menu of a row (MacHistoryRowMenu): play, Explorer, copy the file or the log, delete.
function RowMenu({ row, preparing, actions }: { row: HistoryRow; preparing: boolean; actions: RowActions }) {
  return (
    <>
      <ContextMenuItem icon={<PlayIcon />} disabled={!row.video} onSelect={() => actions.play(row)}>
        {t('Воспроизвести')}
      </ContextMenuItem>
      <ContextMenuItem icon={<FolderIcon />} onSelect={() => actions.reveal(row)}>
        {row.video ? t('Показать в проводнике') : t('Показать лог в проводнике')}
      </ContextMenuItem>
      {row.video && (
        <ContextMenuItem icon={<CopyFileIcon />} disabled={preparing} onSelect={() => actions.copyFile(row)}>
          {t('Копировать файл')}
        </ContextMenuItem>
      )}
      {row.record && (
        <>
          <ContextMenuSeparator />
          <ContextMenuItem icon={<CopyIcon />} onSelect={() => actions.copyLog(row)}>
            {t('Скопировать лог')}
          </ContextMenuItem>
        </>
      )}
      <ContextMenuSeparator />
      {row.kind === 'clip' ? (
        <ContextMenuItem icon={<DeleteIcon />} danger onSelect={() => actions.confirmDelete(row, false)}>
          {t('Удалить запись…')}
        </ContextMenuItem>
      ) : row.video ? (
        <>
          <ContextMenuItem icon={<DeleteIcon />} danger onSelect={() => actions.confirmDelete(row, false)}>
            {t('Удалить тренировку и видео…')}
          </ContextMenuItem>
          <ContextMenuItem onSelect={() => actions.confirmDelete(row, true)}>{t('Удалить только лог, видео оставить…')}</ContextMenuItem>
        </>
      ) : (
        <ContextMenuItem icon={<DeleteIcon />} danger onSelect={() => actions.confirmDelete(row, false)}>
          {t('Удалить тренировку…')}
        </ContextMenuItem>
      )}
    </>
  )
}

function Dash({ title }: { title?: string }) {
  return (
    <span className="hdash" title={title}>
      —
    </span>
  )
}

function Cell({ row, column, preparing, longestEver }: { row: HistoryRow; column: SortKey; preparing: boolean; longestEver: number }) {
  const record = row.record
  switch (column) {
    case 'date':
      return (
        <>
          <Thumbnail row={row} preparing={preparing} />
          <span className="ellipsis">{dayText(row.date)}</span>
        </>
      )
    case 'start':
      return <span className="tabular">{formatTime(row.date)}</span>
    case 'title':
      return (
        <span className={'ellipsis' + (row.kind === 'clip' ? ' muted' : '')} title={row.title}>
          {row.title}
        </span>
      )
    case 'trainers':
      return row.trainers ? (
        <span className="ellipsis" title={row.trainers}>
          {row.trainers}
        </span>
      ) : (
        <Dash />
      )
    case 'exits':
      return record ? <span className="tabular">{t('%lld из %lld', completedExits(record), record.plan.exits.length)}</span> : <Dash />
    case 'falseStarts': {
      const count = record ? falseStarts(record) : 0
      return count > 0 ? (
        <span className="hfalse tabular">
          <FalseStartIcon />
          {count}
        </span>
      ) : (
        <Dash />
      )
    }
    case 'longest': {
      if (!record) return <Dash />
      const value = longestStay(record)
      return (
        <span className="hlongest">
          <span className="hlongest__value tabular">{DurationText.clock(value)}</span>
          <span className="hlongest__track">
            <span className="hlongest__bar" style={{ width: `${longestEver > 0 ? Math.min(100, (value / longestEver) * 100) : 0}%` }} />
          </span>
        </span>
      )
    }
    case 'plan':
      return record ? <span className="tabular muted">{DurationText.clock(longestPlanned(record))}</span> : <Dash />
    case 'duration': {
      const duration = rowDuration(row)
      return duration >= 0 ? <span className="tabular">{DurationText.clock(duration)}</span> : <Dash />
    }
    case 'video':
      return <VideoCell row={row} preparing={preparing} />
  }
}

function VideoCell({ row, preparing }: { row: HistoryRow; preparing: boolean }) {
  const delayed = useDelayed(preparing)
  const video = row.video
  if (!video) return <Dash title={t('Видео нет')} />
  if (preparing) {
    return delayed ? (
      <Tooltip content={t('готовится…')}>
        <span className="hvideo-preparing">
          <Spinner />
        </span>
      </Tooltip>
    ) : null
  }
  if (video.bytes !== null && video.bytes > 0) return <span className="tabular">{formatBytes(video.bytes)}</span>
  // The size is not known (the media scheme does not answer HEAD requests to the page): there is a video.
  return (
    <span className="hvideo-glyph" title={video.duration !== null ? `${t('Видео')} · ${DurationText.clock(video.duration)}` : t('Видео')}>
      <ClipIcon />
    </span>
  )
}

/// Small 16:9 frame at the start of the row (MacHistoryThumbnail): a frame of the video once it has been read,
/// or a quiet tile (the paw for a training kept only as a log) so the column stays aligned.
function Thumbnail({ row, preparing }: { row: HistoryRow; preparing: boolean }) {
  const [onScreen, ref] = useOnScreen<HTMLSpanElement>()
  const fileName = row.video?.exists === false ? null : row.video?.fileName ?? null
  const thumbnail = useThumbnail(fileName, onScreen && !preparing)
  const help = row.kind === 'clip' ? t('Запись без тренировки') : row.video ? t('Тренировка') : t('Тренировка без видео')
  let content: ReactNode = null
  if (!row.video) content = row.kind === 'clip' ? <ClipIcon /> : <PawFilledIcon className="hthumb__paw" />
  else if (thumbnail?.kind === 'image') content = <img src={thumbnail.url} alt="" draggable={false} />
  else if (thumbnail?.kind === 'video') content = <VideoHost element={thumbnail.element} />
  else if (thumbnail?.kind === 'failed') content = <ClipIcon />
  return (
    <span className="hthumb" ref={ref} title={help} aria-hidden>
      {content}
    </span>
  )
}

/// Shows an already loaded <video> (paused on its frame) inside the cell.
function VideoHost({ element }: { element: HTMLVideoElement }) {
  const host = useRef<HTMLSpanElement | null>(null)
  useLayoutEffect(() => {
    const parent = host.current
    if (!parent) return
    parent.appendChild(element)
    return () => {
      if (element.parentElement === parent) parent.removeChild(element)
    }
  }, [element])
  return <span className="hthumb__host" ref={host} />
}

/// Whether the element is (nearly) on screen — only those rows read their frames.
function useOnScreen<T extends HTMLElement>(): [boolean, (element: T | null) => void] {
  const [visible, setVisible] = useState(false)
  const observer = useRef<IntersectionObserver | null>(null)
  const ref = useCallback((element: T | null) => {
    observer.current?.disconnect()
    observer.current = null
    if (!element) return
    observer.current = new IntersectionObserver((entries) => setVisible(entries.some((entry) => entry.isIntersecting)), { rootMargin: '120px 0px' })
    observer.current.observe(element)
  }, [])
  useEffect(() => () => observer.current?.disconnect(), [])
  return [visible, ref]
}
