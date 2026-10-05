import { useEffect, useState } from 'react'

/// True once `active` has stayed true for `delay` ms (MacHistoryDelayed): no flash of a spinner for quick checks.
export function useDelayed(active: boolean, delay = 400): boolean {
  const [shown, setShown] = useState(false)
  useEffect(() => {
    if (!active) {
      setShown(false)
      return
    }
    const timer = window.setTimeout(() => setShown(true), delay)
    return () => window.clearTimeout(timer)
  }, [active, delay])
  return active && shown
}
