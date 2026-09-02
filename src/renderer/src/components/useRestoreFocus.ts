import { useEffect } from 'react'

/**
 * Remembers the element focused when a dialog opens and returns focus to it
 * when the dialog closes or unmounts.
 */
export function useRestoreFocus(): void {
  useEffect(() => {
    const previous =
      document.activeElement instanceof HTMLElement && document.activeElement !== document.body
        ? document.activeElement
        : undefined
    return () => {
      if (previous?.isConnected) previous.focus()
    }
  }, [])
}
