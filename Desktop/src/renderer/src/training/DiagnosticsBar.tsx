import { t } from '@shared/i18n'

/// "Задержка ≈ 1,6 с: сеть 0,4 с + буфер 1,2 с" in the corner of the picture (Settings → Diagnostics → show load).
/// Both parts are measured by the player itself (see CameraPlayer.ts).
export function DiagnosticsBar({ delay }: { delay: { buffer: number; network: number | null } | null }) {
  if (!delay) return null
  const total = delay.buffer + (delay.network ?? 0)
  const tone = total > 2 ? 'var(--danger)' : total > 1.2 ? 'var(--warning)' : 'rgba(255,255,255,0.9)'
  const seconds = (value: number) => value.toLocaleString(undefined, { minimumFractionDigits: 1, maximumFractionDigits: 1 })
  const text =
    delay.network === null
      ? t('Задержка ≥ %@ с: только буфер плеера', seconds(delay.buffer))
      : t('Задержка ≈ %@ с: сеть %@ с + буфер %@ с', seconds(total), seconds(delay.network), seconds(delay.buffer))
  return (
    <div className="camera__diagnostics tabular" style={{ color: tone }}>
      {text}
    </div>
  )
}
