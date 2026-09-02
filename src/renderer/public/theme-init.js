// Applies the stored theme before first paint to avoid a flash of the wrong theme.
// Loaded as a classic script ahead of the module bundle (the CSP forbids inline
// scripts), so it must stay dependency-free. Keep in sync with src/lib/theme.ts.
;(function () {
  try {
    var stored = window.localStorage.getItem('dbbbb.theme')
    var dark =
      stored === 'dark' ||
      (stored !== 'light' &&
        typeof window.matchMedia === 'function' &&
        window.matchMedia('(prefers-color-scheme: dark)').matches)
    var resolved = dark ? 'dark' : 'light'
    document.documentElement.dataset.theme = resolved
    document.documentElement.style.colorScheme = resolved
  } catch (error) {
    // Storage blocked: leave the default light theme from styles.css in place.
  }
})()
