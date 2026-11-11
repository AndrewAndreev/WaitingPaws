import { useCallback, useEffect, useMemo, useRef, useState, type PointerEvent } from 'react'
import { t } from '@shared/i18n'
import { coreLocale } from '@core/localization'
import { SessionLogFormatter, type TrainingRecord } from '@core/sessionLog'
import type { HistoryList } from '@shared/api'
import { call, callStrict, toast, ui, useStore } from '../store'
import { formatTime } from '../model'
import { formatBytes } from '../format'
import {
  ChevronDownIcon,
  CloseIcon,
  CopyIcon,
  DeleteIcon,
  FolderIcon,
  InspectorFilledIcon,
  InspectorIcon,
  NoResultsIcon,
  PawIcon,
  ProgressChartIcon,
  SearchIcon,
  ClipIcon,
} from '../ui/icons'
import { Button, Dialog, Menu, MenuContent, MenuItem, MenuSeparator, MenuTrigger, Segmented, Tooltip } from '../ui/kit'
import '../styles/history.css'
import {
  buildRows,
  filterRows,
  keyOf,
  longestStay,
  neighbourAfterRemoval,
  nextSort,
  rowKey,
  sortRows,
  type ClipFile,
  type HistoryRow,
  type Scope,
} from './logic'
import { dayMonth, recordingsText, trainingsAccusative, trainingsText } from './format'
import { checkFiles, useMedia } from './media'
import { INSPECTOR_MAX, INSPECTOR_MIN, historyUI, player, remember, useHistoryUI } from './state'
import { HistoryTable, type RowActions } from './HistoryTable'
import { ProgressPanel } from './ProgressPanel'
import { Inspector } from './Inspector'

/// «История» (the Mac app's History window as a page): progress over the last weeks on top, every training and
/// recording in a sortable table, the selected row in the inspector on the right (video with the exits, totals,
/// the log for the trainer).
export function HistoryPage() {
  const historyRevision = useStore((store) => store.app?.historyRevision ?? 0)
  const finalizingKey = useStore((store) => (store.app?.finalizing ?? []).join('\n'))
  const [list, setList] = useState<{ records: TrainingRecord[]; clips: ClipFile[]; revision: number } | null>(null)
  const scope = useHistoryUI((store) => store.scope)
  const search = useHistoryUI((store) => store.search)
  const sort = useHistoryUI((store) => store.sort)
  const showsInspector = useHistoryUI((store) => store.showsInspector)
  const inspectorWidth = useHistoryUI((store) => store.inspectorWidth)
  const scrollRequest = useHistoryUI((store) => store.scrollRequest)
  const videos = useMedia((store) => store.videos)
  const selection = useStore((store) => store.historySelection)
  const finalizing = useMemo(() => new Set<string>(finalizingKey ? finalizingKey.split('\n') : []), [finalizingKey])

  // History and clips: fetched again whenever they change (and when a file finishes finalizing: new sizes).
  useEffect(() => {
    let cancelled = false
    const revision = historyRevision
    void call('history.list').then((result) => {
      if (cancelled || !result) return
      const { records, clips } = result as HistoryList
      setList({ records: records as TrainingRecord[], clips, revision })
    })
    return () => {
      cancelled = true
    }
  }, [historyRevision, finalizingKey])

  // Which training videos exist, their sizes and lengths.
  useEffect(() => {
    if (!list) return
    const names = list.records.flatMap((record) => (record.recordingFileName ? [record.recordingFileName] : []))
    void checkFiles(names, list.clips, finalizing)
  }, [list, finalizing])

  const records = useMemo(() => list?.records ?? [], [list])
  const clips = useMemo(() => list?.clips ?? [], [list])
  const untitled = t('Recording without training')
  const allRows = useMemo(() => buildRows(records, clips, videos, untitled), [records, clips, videos, untitled])
  const rows = useMemo(() => sortRows(filterRows(allRows, scope, search), sort, coreLocale()), [allRows, scope, search, sort])
  const selectedKey = selection ? rowKey(selection.kind, selection.id) : null
  const selected = allRows.find((row) => keyOf(row) === selectedKey) ?? null
  const isEmpty = list !== null && records.length === 0 && clips.length === 0
  const longestEver = useMemo(() => records.reduce((best, record) => Math.max(best, longestStay(record)), 0), [records])

  /// The key of the selection the page has dealt with (a different one was set from elsewhere).
  const handled = useRef<string | null>(null)
  const select = useCallback((row: HistoryRow | null) => {
    handled.current = row ? keyOf(row) : null
    const current = ui.get().historySelection
    if (row === null) {
      if (current !== null) ui.set({ historySelection: null })
      return
    }
    if (!current || current.kind !== row.kind || current.id !== row.id) ui.set({ historySelection: { kind: row.kind, id: row.id } })
  }, [])

  // A row opened from elsewhere (the summary dialog): clear the filters that hide it and bring it into view.
  useEffect(() => {
    if (!list || !selectedKey || handled.current === selectedKey) return
    const row = allRows.find((item) => keyOf(item) === selectedKey)
    if (!row) return
    handled.current = selectedKey
    const { scope: currentScope, search: currentSearch } = historyUI.get()
    if (!filterRows([row], currentScope, currentSearch).length) historyUI.set({ scope: 'all', search: '' })
    historyUI.set({ scrollRequest: historyUI.get().scrollRequest + 1 })
  }, [list, selectedKey, allRows])

  // Keep a visible row selected: the first one when the selection vanished or got filtered out (not while the
  // list is older than the history the selection may point at).
  const rowIds = rows.map(keyOf).join('\n')
  useEffect(() => {
    if (!list || list.revision !== historyRevision) return
    const current = selectedKey ? allRows.find((row) => keyOf(row) === selectedKey) : undefined
    const { scope: currentScope, search: currentSearch } = historyUI.get()
    if (current && filterRows([current], currentScope, currentSearch).length) return
    select(rows[0] ?? null)
  }, [rowIds, list, selectedKey]) // eslint-disable-line react-hooks/exhaustive-deps

  /// Selects a row from outside the table (the chart): clears filters that hide it and scrolls to it.
  const reveal = useCallback(
    (key: string) => {
      const row = allRows.find((item) => keyOf(item) === key)
      if (!row) return
      if (!rows.some((item) => keyOf(item) === key)) historyUI.set({ scope: 'all', search: '' })
      select(row)
      historyUI.set({ scrollRequest: historyUI.get().scrollRequest + 1 })
    },
    [allRows, rows, select],
  )

  const copyLog = useCallback((row: HistoryRow) => {
    if (!row.record) return
    void call('clipboard.writeText', SessionLogFormatter.text(row.record))
    const key = keyOf(row)
    historyUI.set({ copiedKey: key })
    window.setTimeout(() => {
      if (historyUI.get().copiedKey === key) historyUI.set({ copiedKey: null })
    }, 1600)
  }, [])

  const actions: RowActions = useMemo(
    () => ({
      select,
      activate: (row) => {
        select(row)
        if (row.video) {
          historyUI.set({ showsInspector: true })
          player.play(row.video.fileName)
        } else {
          historyUI.set({ showsInspector: true })
        }
      },
      togglePlayback: (row) => {
        if (!row.video) return
        historyUI.set({ showsInspector: true })
        player.toggle(row.video.fileName)
      },
      play: (row) => {
        if (!row.video) return
        select(row)
        historyUI.set({ showsInspector: true })
        player.play(row.video.fileName)
      },
      reveal: (row) => {
        if (row.video) void call('shell.showItem', 'recording', row.video.fileName)
        else if (row.record) void call('shell.showItem', 'log', row.record.id)
      },
      copyFile: (row) => {
        if (!row.video) return
        callStrict('shell.copyFile', row.video.fileName).then(
          () => toast({ title: t('Video copied — paste it into a messenger or a folder'), kind: 'success' }),
          (error: Error) => toast({ title: error.message, kind: 'danger' }),
        )
      },
      copyLog,
      confirmDelete: (row, onlyLog) => {
        // Without a video there is only one way to delete a training.
        const way = row.kind === 'clip' || (row.record && !row.video) ? false : onlyLog
        historyUI.set({ pendingDelete: { row, onlyLog: way } })
      },
    }),
    [select, copyLog],
  )

  const currentRow = useRef<HistoryRow | null>(null)
  currentRow.current = selected

  // Page shortcuts: Ctrl+Shift+C copies the log, Ctrl+F finds, Ctrl+Alt+I shows/hides the inspector,
  // Delete deletes, Space plays (outside text fields; the table handles its own keys when focused).
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (document.querySelector('[role="dialog"], [role="menu"]')) return
      const target = event.target as HTMLElement | null
      const typing = !!target && (target.isContentEditable || ['INPUT', 'TEXTAREA', 'SELECT'].includes(target.tagName))
      const key = event.key.toLowerCase()
      const ctrl = event.ctrlKey || event.metaKey
      const row = currentRow.current
      if (ctrl && event.shiftKey && !event.altKey && key === 'c') {
        if (row?.record) {
          event.preventDefault()
          copyLog(row)
        }
        return
      }
      if (ctrl && !event.shiftKey && !event.altKey && key === 'f') {
        event.preventDefault()
        document.querySelector<HTMLInputElement>('.hsearch input')?.focus()
        return
      }
      if (ctrl && event.altKey && key === 'i') {
        event.preventDefault()
        toggleInspector()
        return
      }
      if (typing || ctrl || event.altKey || !row) return
      const inTable = !!target?.closest('.htable')
      if (inTable) return
      const onControl = !!target?.closest('button, a, video, [role="slider"]')
      if (event.key === 'Delete' && !onControl) {
        event.preventDefault()
        actions.confirmDelete(row, null)
      } else if (event.key === ' ' && !onControl && row.video) {
        event.preventDefault()
        if (!event.repeat) actions.togglePlayback(row)
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [actions, copyLog])

  // A hidden inspector stops the video.
  useEffect(() => {
    if (!showsInspector) player.pause()
  }, [showsInspector])

  const bytes = useMemo(() => {
    let total = 0
    for (const row of allRows) total += row.video?.bytes ?? 0
    return total
  }, [allRows])

  return (
    <div className={'history' + (showsInspector && !isEmpty ? ' history--inspector' : '')} style={{ ['--inspector-width' as string]: `${inspectorWidth}px` }}>
      <CommandBar
        isEmpty={isEmpty || list === null}
        selected={selected}
        summary={summaryText(records.length, clips.length, bytes)}
        actions={actions}
      />
      {list === null ? (
        <div className="history__main" />
      ) : isEmpty ? (
        <div className="history__main">
          <div className="empty-state history__empty">
            <PawIcon style={{ width: 40, height: 40 }} />
            <div className="empty-state__title h2">{t('No Trainings Yet')}</div>
            <div className="history__empty-text">
              {t('Paste the trainer’s schedule (Ctrl+Shift+V) and run a training — its log, video and a chart of how long the dog calmly waits outside will appear here.')}
            </div>
            <Button variant="primary" onClick={() => ui.set({ route: 'training' })} style={{ marginTop: 8 }}>
              {t('Go to Training')}
            </Button>
          </div>
        </div>
      ) : (
        <div className="history__main">
          {records.length === 0 ? (
            <div className="history__noprogress muted">
              <ProgressChartIcon />
              {t('The progress chart will appear after the first training.')}
            </div>
          ) : (
            <ProgressPanel records={records} selectedId={selected?.record?.id ?? null} onReveal={(id) => reveal(rowKey('record', id))} />
          )}
          <HistoryTable
            rows={rows}
            selectedKey={selectedKey}
            sort={sort}
            onSort={(key) => historyUI.set({ sort: nextSort(historyUI.get().sort, key) })}
            longestEver={longestEver}
            finalizing={finalizing}
            scrollRequest={scrollRequest}
            actions={actions}
            empty={<NoRows scope={scope} search={search} />}
          />
        </div>
      )}
      {showsInspector && !isEmpty && list !== null && (
        <aside className="history__inspector" aria-label={t('Inspector')}>
          <Splitter />
          <div className="hinspector__scroll" key={selected ? keyOf(selected) : 'none'}>
            <Inspector row={selected} preparing={selected?.video ? finalizing.has(selected.video.fileName) : false} actions={actions} />
          </div>
        </aside>
      )}
      <DeleteDialog visible={rows} onDeleted={select} />
      <DeleteAllDialog trainings={records.length} clips={clips.length} />
    </div>
  )

  function toggleInspector() {
    const next = !historyUI.get().showsInspector
    historyUI.set({ showsInspector: next })
    remember('inspector', next)
  }
}

/// "11 тренировок, 3 записи · 5,8 ГБ".
function summaryText(trainings: number, clips: number, bytes: number): string {
  if (trainings === 0 && clips === 0) return ''
  const parts: string[] = []
  if (trainings > 0 || clips === 0) parts.push(trainingsText(trainings))
  if (clips > 0) parts.push(recordingsText(clips))
  return parts.join(', ') + (bytes > 0 ? ' · ' + formatBytes(bytes) : '')
}

// MARK: - Command bar

function CommandBar({ isEmpty, selected, summary, actions }: { isEmpty: boolean; selected: HistoryRow | null; summary: string; actions: RowActions }) {
  const scope = useHistoryUI((store) => store.scope)
  const showsInspector = useHistoryUI((store) => store.showsInspector)
  const copied = useHistoryUI((store) => (selected ? store.copiedKey === keyOf(selected) : false))
  const explorerHelp = selected?.video ? t('Show the video in Explorer') : selected?.record ? t('Show Log in Explorer') : t('Show the history folder in Explorer')
  return (
    <div className="hbar" role="toolbar" aria-label={t('History')}>
      <Segmented<Scope>
        value={scope}
        disabled={isEmpty}
        onChange={(value) => historyUI.set({ scope: value })}
        options={[
          { value: 'all', label: t('All') },
          { value: 'trainings', label: t('Trainings') },
          { value: 'clips', label: t('Videos Only') },
        ]}
      />
      <SearchBox disabled={isEmpty} />
      <span className="hbar__summary ellipsis tabular">{summary}</span>
      <span className="spacer" />
      <Tooltip content={t('Copy the log for the trainer') + ' (Ctrl+Shift+C)'}>
        <Button variant="subtle" icon={<CopyIcon />} disabled={!selected?.record} onClick={() => selected && actions.copyLog(selected)}>
          <span className="hbar__label">{copied ? t('Copied') : t('Copy Log')}</span>
        </Button>
      </Tooltip>
      <Tooltip content={explorerHelp}>
        <Button
          variant="subtle"
          iconOnly
          icon={<FolderIcon />}
          aria-label={explorerHelp}
          onClick={() => (selected ? actions.reveal(selected) : void call('shell.showItem', 'documents'))}
        />
      </Tooltip>
      <Menu>
        <Tooltip content={t('Delete selected|items') + ' (Delete)'}>
          <MenuTrigger asChild>
            <button type="button" className="btn btn--subtle" disabled={isEmpty}>
              <DeleteIcon />
              <span className="hbar__label">{t('Delete')}</span>
              <ChevronDownIcon className="hbar__chevron" />
            </button>
          </MenuTrigger>
        </Tooltip>
        <MenuContent align="end">
          {selected && <DeleteItems row={selected} actions={actions} />}
          {selected && <MenuSeparator />}
          <MenuItem icon={<DeleteIcon />} danger onSelect={() => historyUI.set({ confirmDeleteAll: true })}>
            {t('Delete All…')}
          </MenuItem>
        </MenuContent>
      </Menu>
      <span className="hbar__sep" />
      <Tooltip content={(showsInspector ? t('Hide inspector') : t('Show inspector')) + ' (Ctrl+Alt+I)'}>
        <Button
          variant="subtle"
          iconOnly
          aria-pressed={showsInspector}
          aria-label={t('Inspector')}
          disabled={isEmpty}
          icon={showsInspector ? <InspectorFilledIcon /> : <InspectorIcon />}
          onClick={() => {
            const next = !showsInspector
            historyUI.set({ showsInspector: next })
            remember('inspector', next)
          }}
        />
      </Tooltip>
    </div>
  )
}

/// Delete commands for one row (MacHistoryDeleteItems); each asks for confirmation.
function DeleteItems({ row, actions }: { row: HistoryRow; actions: RowActions }) {
  if (row.kind === 'clip') {
    return (
      <MenuItem icon={<DeleteIcon />} danger onSelect={() => actions.confirmDelete(row, false)}>
        {t('Delete Recording…')}
      </MenuItem>
    )
  }
  return (
    <>
      <MenuItem icon={<DeleteIcon />} danger onSelect={() => actions.confirmDelete(row, false)}>
        {row.video ? t('Delete Training and Video…') : t('Delete Training…')}
      </MenuItem>
      {row.video && <MenuItem onSelect={() => actions.confirmDelete(row, true)}>{t('Delete Log Only, Keep Video…')}</MenuItem>}
    </>
  )
}

function SearchBox({ disabled }: { disabled: boolean }) {
  const search = useHistoryUI((store) => store.search)
  return (
    <div className="hsearch">
      <SearchIcon className="hsearch__icon" />
      <input
        className="input"
        type="search"
        placeholder={t('Search')}
        aria-label={t('Search')}
        value={search}
        disabled={disabled}
        spellCheck={false}
        onChange={(event) => historyUI.set({ search: event.target.value })}
        onKeyDown={(event) => {
          if (event.key === 'Escape' && search) {
            event.preventDefault()
            event.stopPropagation()
            historyUI.set({ search: '' })
          } else if (event.key === 'ArrowDown' || event.key === 'Enter') {
            event.preventDefault()
            document.querySelector<HTMLElement>('.htable')?.focus()
          }
        }}
      />
      {search && (
        <button type="button" className="hsearch__clear" aria-label={t('Clear search')} onClick={() => historyUI.set({ search: '' })}>
          <CloseIcon />
        </button>
      )}
    </div>
  )
}

function NoRows({ scope, search }: { scope: Scope; search: string }) {
  if (search.trim()) {
    return (
      <div className="empty-state htable__empty">
        <NoResultsIcon style={{ width: 32, height: 32 }} />
        <div className="empty-state__title">{t('No Results for “%@”', search.trim())}</div>
        <div>{t('Check the spelling or try a new search.')}</div>
      </div>
    )
  }
  if (scope === 'clips') {
    return (
      <div className="empty-state htable__empty">
        <ClipIcon style={{ width: 32, height: 32 }} />
        <div className="empty-state__title">{t('No Recordings Without a Training')}</div>
        <div>{t('Videos recorded with the record button outside a training, and videos whose log was deleted, appear here.')}</div>
      </div>
    )
  }
  return (
    <div className="empty-state htable__empty">
      <PawIcon style={{ width: 32, height: 32 }} />
      <div className="empty-state__title">{t('No Trainings Yet|window')}</div>
      <div>{t('There are only recordings without a training — find them under “Videos Only”.')}</div>
    </div>
  )
}

// MARK: - Inspector width

function Splitter() {
  const start = useRef<{ x: number; width: number } | null>(null)
  const onMove = (event: PointerEvent<HTMLDivElement>) => {
    if (!start.current) return
    const width = Math.min(INSPECTOR_MAX, Math.max(INSPECTOR_MIN, start.current.width + (start.current.x - event.clientX)))
    historyUI.set({ inspectorWidth: width })
  }
  return (
    <div
      className="hsplitter"
      role="separator"
      aria-orientation="vertical"
      aria-label={t('Inspector width')}
      onPointerDown={(event) => {
        event.currentTarget.setPointerCapture(event.pointerId)
        start.current = { x: event.clientX, width: historyUI.get().inspectorWidth }
      }}
      onPointerMove={onMove}
      onPointerUp={() => {
        start.current = null
        remember('width', historyUI.get().inspectorWidth)
      }}
      onDoubleClick={() => {
        historyUI.set({ inspectorWidth: 360 })
        remember('width', 360)
      }}
    />
  )
}

// MARK: - Delete

function DeleteDialog({ visible, onDeleted }: { visible: HistoryRow[]; onDeleted: (row: HistoryRow | null) => void }) {
  const pending = useHistoryUI((store) => store.pendingDelete)
  const close = () => historyUI.set({ pendingDelete: null })
  if (!pending) return null
  const { row, onlyLog } = pending
  const day = dayMonth(row.date)
  const time = formatTime(row.date)
  const what = row.kind === 'clip' ? t('Recording from %@, %@.', day, time) : t('“%@”, %@, %@.', row.title, day, time)
  const title = row.kind === 'clip' ? t('Delete Recording?') : onlyLog === true ? t('Delete Training Log?') : t('Delete Training?')
  const description = onlyLog === true ? t('%@ The video will stay in History as a recording without a training.', what) : what

  const remove = (logOnly: boolean) => {
    close()
    const key = keyOf(row)
    const selection = ui.get().historySelection
    if (selection && rowKey(selection.kind, selection.id) === key) onDeleted(neighbourAfterRemoval(visible, key))
    if (row.video) player.pause()
    if (row.kind === 'clip') {
      void call('history.deleteClip', row.id)
    } else {
      void call('history.delete', row.id, !logOnly)
      // The video stays as a recording without a training: keep it selected.
      if (logOnly && row.video) ui.set({ historySelection: { kind: 'clip', id: row.video.fileName } })
    }
  }

  return (
    <Dialog
      open
      onOpenChange={(open) => !open && close()}
      icon={<DeleteIcon style={{ color: 'var(--danger)', width: 24, height: 24, marginTop: 2 }} />}
      title={title}
      description={description}
      width={row.kind === 'record' && onlyLog === null ? 700 : 480}
      hideClose
      footer={
        <>
          {row.kind === 'record' && onlyLog === null && <Button onClick={() => remove(true)}>{t('Delete Log Only, Keep Video')}</Button>}
          <span className="spacer" />
          <Button onClick={close}>{t('Cancel')}</Button>
          {row.kind === 'clip' ? (
            <Button variant="danger-solid" autoFocus onClick={() => remove(false)}>
              {t('Delete Recording')}
            </Button>
          ) : onlyLog === true ? (
            <Button variant="danger-solid" autoFocus onClick={() => remove(true)}>
              {t('Delete Log')}
            </Button>
          ) : (
            <Button variant="danger-solid" autoFocus onClick={() => remove(false)}>
              {row.video ? t('Delete Training and Video') : t('Delete Training')}
            </Button>
          )}
        </>
      }
    />
  )
}

function DeleteAllDialog({ trainings, clips }: { trainings: number; clips: number }) {
  const open = useHistoryUI((store) => store.confirmDeleteAll)
  const close = () => historyUI.set({ confirmDeleteAll: false })
  if (!open) return null
  const trainingsPart = trainingsAccusative(trainings)
  const clipsPart = recordingsText(clips)
  const action = clips === 0 ? t('Delete %@', trainingsPart) : trainings === 0 ? t('Delete %@', clipsPart) : t('Delete %@ and %@', trainingsPart, clipsPart)
  return (
    <Dialog
      open
      onOpenChange={(value) => !value && close()}
      icon={<DeleteIcon style={{ color: 'var(--danger)', width: 24, height: 24, marginTop: 2 }} />}
      title={t('Delete All History?')}
      description={t('Logs and videos will be deleted from this computer.')}
      width={480}
      hideClose
      footer={
        <>
          <Button autoFocus onClick={close}>
            {t('Cancel')}
          </Button>
          <Button
            variant="danger-solid"
            onClick={() => {
              close()
              player.pause()
              ui.set({ historySelection: null })
              void call('history.deleteAll')
            }}
          >
            {action}
          </Button>
        </>
      }
    />
  )
}
