import { useEffect, useState } from 'react'
import { plural, t } from '@shared/i18n'
import { call, useApp } from '../store'
import { formatBytes } from '../format'
import { Button, Dialog } from '../ui/kit'
import { DeleteIcon, FolderIcon, LogIcon, StorageIcon, VideoIcon } from '../ui/icons'
import { Group, PaneHeader, Row, Value } from './rows'

interface Usage {
  bytes: number
  videos: number
  trainings: number
  clips: number
}

/// Запись и файлы: where videos and logs are, how much space they take, deleting the whole history.
export function RecordingPane() {
  const app = useApp()
  const [usage, setUsage] = useState<Usage | null>(null)
  const [confirmDelete, setConfirmDelete] = useState(false)
  const [deleting, setDeleting] = useState(false)
  const desktop = app.platform !== 'web'

  useEffect(() => {
    let cancelled = false
    void Promise.all([call('recordings.size'), call('history.list')]).then(([size, list]) => {
      if (cancelled) return
      setUsage({ bytes: size?.bytes ?? 0, videos: size?.files ?? 0, trainings: list?.records.length ?? 0, clips: list?.clips.length ?? 0 })
    })
    return () => {
      cancelled = true
    }
    // Again when history changes and when a recording has been finalized (its size changes).
  }, [app.historyRevision, app.finalizing.length])

  const usageText = (() => {
    if (!usage) return t('Calculating…')
    if (usage.videos === 0 && usage.trainings === 0) return usage.bytes > 0 ? t('%@ · no trainings yet', formatBytes(usage.bytes)) : t('Nothing yet')
    // The size is that of the videos; logs alone take next to nothing.
    const parts = usage.bytes > 0 ? [formatBytes(usage.bytes)] : []
    if (usage.videos > 0) parts.push(plural(usage.videos, ['%d video', '%d videos'], ['%d видео', '%d видео', '%d видео']))
    if (usage.trainings > 0) parts.push(plural(usage.trainings, ['%d log', '%d logs'], ['%d лог', '%d лога', '%d логов']))
    return parts.join(' · ')
  })()

  const nothing = usage !== null && usage.trainings === 0 && usage.clips === 0
  const deleteAll = async () => {
    setDeleting(true)
    await call('history.deleteAll')
    setDeleting(false)
    setConfirmDelete(false)
  }

  return (
    <>
      <PaneHeader title={t('Recording & Files')} description={t('Training videos and logs are stored on this computer.')} />
      {desktop && (
        <Group title={t('Folders')}>
          <FolderRow icon={<FolderIcon />} title="Waiting Paws" path={app.paths.documents} kind="documents" />
          <FolderRow icon={<VideoIcon />} title={t('Video')} path={app.paths.recordings} kind="recordings" />
          <FolderRow icon={<LogIcon />} title={t('Training Logs')} path={app.paths.sessions} kind="sessions" />
        </Group>
      )}
      <Group title={t('Disk Space')}>
        <Row icon={<StorageIcon />} title={t('Used')} description={t('Videos and logs of all trainings and standalone recordings.')}>
          <Value>{usageText}</Value>
        </Row>
      </Group>
      <Group title={t('History')}>
        <Row icon={<DeleteIcon />} title={t('Delete all history')} description={t('Every training with its log and video, and standalone recordings. This can’t be undone.')}>
          <Button variant="danger" disabled={nothing || deleting} onClick={() => setConfirmDelete(true)}>
            {t('Delete All History…')}
          </Button>
        </Row>
      </Group>
      <Dialog
        open={confirmDelete}
        onOpenChange={(open) => !deleting && setConfirmDelete(open)}
        title={t('Delete All History?')}
        description={t('Logs and videos will be deleted from this computer. This can’t be undone.')}
        hideClose
        width={480}
        footer={
          <>
            <Button autoFocus disabled={deleting} onClick={() => setConfirmDelete(false)}>
              {t('Cancel')}
            </Button>
            <Button variant="danger-solid" disabled={deleting} onClick={() => void deleteAll()}>
              {usage && usage.trainings > 0 && usage.clips > 0 ? t('Delete Trainings (%lld) and Recordings (%lld)', usage.trainings, usage.clips) : t('Delete All')}
            </Button>
          </>
        }
      />
    </>
  )
}

function FolderRow({ icon, title, path, kind }: { icon: React.ReactNode; title: string; path: string; kind: 'documents' | 'recordings' | 'sessions' }) {
  return (
    <Row
      icon={icon}
      title={title}
      description={
        <span className="srow__path mono selectable" title={path}>
          {path}
        </span>
      }
    >
      <Button onClick={() => void call('shell.showItem', kind)}>{t('Show in Explorer')}</Button>
    </Row>
  )
}
