import { useStore } from '../store'
import { CheckIcon, ErrorIcon, InfoIcon, WarningIcon } from '../ui/icons'

export function Toasts() {
  const toasts = useStore((store) => store.toasts)
  return (
    <div className="toast-region" role="status" aria-live="polite">
      {toasts.map((toast) => (
        <div className="toast" key={toast.id}>
          <span style={{ color: toast.kind === 'danger' ? 'var(--danger)' : toast.kind === 'warning' ? 'var(--warning)' : toast.kind === 'success' ? 'var(--success)' : 'var(--info)' }}>
            {toast.kind === 'danger' ? <ErrorIcon /> : toast.kind === 'warning' ? <WarningIcon /> : toast.kind === 'success' ? <CheckIcon /> : <InfoIcon />}
          </span>
          <div className="grow">
            <div className="toast__title">{toast.title}</div>
            {toast.detail && <div className="toast__detail">{toast.detail}</div>}
          </div>
        </div>
      ))}
    </div>
  )
}
