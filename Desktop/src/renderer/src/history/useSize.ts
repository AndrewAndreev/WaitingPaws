import { useCallback, useEffect, useRef, useState } from 'react'

/// The element's content size, kept up to date with a ResizeObserver (charts, strips, column fitting).
export function useSize<T extends HTMLElement>(): [{ width: number; height: number }, (element: T | null) => void] {
  const [size, setSize] = useState({ width: 0, height: 0 })
  const observer = useRef<ResizeObserver | null>(null)
  const ref = useCallback((element: T | null) => {
    observer.current?.disconnect()
    observer.current = null
    if (!element) return
    const measure = () => {
      const width = element.clientWidth
      const height = element.clientHeight
      setSize((previous) => (previous.width === width && previous.height === height ? previous : { width, height }))
    }
    measure()
    observer.current = new ResizeObserver(measure)
    observer.current.observe(element)
  }, [])
  useEffect(() => () => observer.current?.disconnect(), [])
  return [size, ref]
}
