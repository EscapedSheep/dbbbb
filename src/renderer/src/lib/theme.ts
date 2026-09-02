export type ThemePreference = 'light' | 'dark' | 'system'
export type ResolvedTheme = 'light' | 'dark'

export const THEME_STORAGE_KEY = 'dbbbb.theme'

export function resolveTheme(
  preference: ThemePreference,
  systemPrefersDark: boolean
): ResolvedTheme {
  if (preference === 'system') {
    return systemPrefersDark ? 'dark' : 'light'
  }
  return preference
}

export function readThemePreference(): ThemePreference {
  try {
    const stored = window.localStorage.getItem(THEME_STORAGE_KEY)
    return stored === 'light' || stored === 'dark' || stored === 'system' ? stored : 'system'
  } catch {
    // localStorage can throw (e.g. SecurityError when storage is blocked); this runs
    // during the initial render, so fall back instead of crashing the render tree.
    return 'system'
  }
}

export function applyTheme(preference: ThemePreference, systemPrefersDark: boolean): ResolvedTheme {
  const resolved = resolveTheme(preference, systemPrefersDark)
  document.documentElement.dataset.theme = resolved
  document.documentElement.style.colorScheme = resolved
  if (readThemePreference() !== preference) {
    try {
      window.localStorage.setItem(THEME_STORAGE_KEY, preference)
    } catch {
      // Storage may be blocked or out of quota; the theme still applies for this session.
    }
  }
  return resolved
}

