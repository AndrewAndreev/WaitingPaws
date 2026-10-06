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
    if (!usage) return t('Считаем…')
    if (usage.videos === 0 && usage.trainings === 0) return usage.bytes > 0 ? t('%@ · тренировок пока нет', formatBytes(usage.bytes)) : t('Пока пусто')
    // The size is that of the videos; logs alone take next to nothing.
    const parts = usage.bytes > 0 ? [formatBytes(usage.bytes)] : []
    if (usage.videos > 0) parts.push(plural(usage.videos, ['%d видео', '%d видео', '%d видео'], ['%d video', '%d videos']))
    if (usage.trainings > 0) parts.push(plural(usage.trainings, ['%d лог', '%d лога', '%d логов'], ['%d log', '%d logs']))
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
      <PaneHeader title={t('Запись и файлы')} description={t('Видео и логи тренировок хранятся на этом компьютере.')} />
      {desktop && (
        <Group title={t('Папки')}>
          <FolderRow icon={<FolderIcon />} title="Waiting Paws" path={app.paths.documents} kind="documents" />
          <FolderRow icon={<VideoIcon />} title={t('Видео')} path={app.paths.recordings} kind="recordings" />
          <FolderRow icon={<LogIcon />} title={t('Логи тренировок')} path={app.paths.sessions} kind="sessions" />
        </Group>
      )}
      <Group title={t('Место на диске')}>
        <Row icon={<StorageIcon />} title={t('Занято')} description={t('Видео и логи всех тренировок и отдельных записей.')}>
          <Value>{usageText}</Value>
        </Row>
      </Group>
      <Group title={t('История')}>
        <Row icon={<DeleteIcon />} title={t('Удалить всю историю')} description={t('Все тренировки с их логами и видео, и отдельные записи. Это нельзя отменить.')}>
          <Button variant="danger" disabled={nothing || deleting} onClick={() => setConfirmDelete(true)}>
            {t('Удалить всю историю…')}
          </Button>
        </Row>
      </Group>
      <Dialog
        open={confirmDelete}
        onOpenChange={(open) => !deleting && setConfirmDelete(open)}
        title={t('Удалить всю историю?')}
        description={t('Логи и видео будут удалены с этого компьютера. Это нельзя отменить.')}
        hideClose
        width={480}
        footer={
          <>
            <Button autoFocus disabled={deleting} onClick={() => setConfirmDelete(false)}>
              {t('Отмена')}
            </Button>
            <Button variant="danger-solid" disabled={deleting} onClick={() => void deleteAll()}>
              {usage && usage.trainings > 0 && usage.clips > 0 ? t('Удалить тренировки (%lld) и записи (%lld)', usage.trainings, usage.clips) : t('Удалить всё')}
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
      <Button onClick={() => void call('shell.showItem', kind)}>{t('Показать в проводнике')}</Button>
    </Row>
  )
}
