import { beforeEach, describe, expect, it, vi } from 'vitest'
import { applyTheme, readThemePreference, resolveTheme, THEME_STORAGE_KEY } from './theme'

describe('resolveTheme', () => {
  it('keeps an explicit theme regardless of the system setting', () => {
    expect(resolveTheme('light', true)).toBe('light')
    expect(resolveTheme('dark', false)).toBe('dark')
  })

  it('follows the system setting for system mode', () => {
    expect(resolveTheme('system', true)).toBe('dark')
    expect(resolveTheme('system', false)).toBe('light')
  })
})

describe('readThemePreference', () => {
  beforeEach(() => {
    window.localStorage.clear()
  })

  it('returns the stored preference and falls back to system for unknown values', () => {
    expect(readThemePreference()).toBe('system')
    window.localStorage.setItem(THEME_STORAGE_KEY, 'dark')
    expect(readThemePreference()).toBe('dark')
    window.localStorage.setItem(THEME_STORAGE_KEY, 'neon')
    expect(readThemePreference()).toBe('system')
  })

  it('falls back to system when storage throws', () => {
    vi.spyOn(Storage.prototype, 'getItem').mockImplementation(() => {
      throw new DOMException('Access is denied', 'SecurityError')
    })
    expect(readThemePreference()).toBe('system')
  })
})

describe('applyTheme', () => {
  beforeEach(() => {
    window.localStorage.clear()
  })

  it('applies the resolved theme to the document and persists the preference', () => {
    expect(applyTheme('dark', false)).toBe('dark')
    expect(document.documentElement.dataset.theme).toBe('dark')
    expect(document.documentElement.style.colorScheme).toBe('dark')
    expect(window.localStorage.getItem(THEME_STORAGE_KEY)).toBe('dark')
  })

  it('writes storage only when the preference changes', () => {
    window.localStorage.setItem(THEME_STORAGE_KEY, 'light')
    const setItem = vi.spyOn(Storage.prototype, 'setItem')

    applyTheme('light', false)
    expect(setItem).not.toHaveBeenCalled()

    applyTheme('dark', false)
    expect(setItem).toHaveBeenCalledWith(THEME_STORAGE_KEY, 'dark')
  })

  it('still applies the theme when storage is blocked', () => {
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => {
      throw new DOMException('Access is denied', 'SecurityError')
    })
    expect(applyTheme('system', true)).toBe('dark')
    expect(document.documentElement.dataset.theme).toBe('dark')
  })
})
