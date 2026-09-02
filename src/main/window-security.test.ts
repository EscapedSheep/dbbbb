// @vitest-environment node
import { describe, expect, it } from 'vitest'
import {
  decideWindowOpen,
  FILE_RENDERER_CSP,
  isNavigationAllowed,
  isPermissionGranted
} from './window-security'

describe('window security defaults', () => {
  it('locks the file renderer CSP down to same-origin read-only resources', () => {
    expect(FILE_RENDERER_CSP).toContain("default-src 'self'")
    expect(FILE_RENDERER_CSP).toContain("script-src 'self'")
    expect(FILE_RENDERER_CSP).toContain("connect-src 'none'")
    expect(FILE_RENDERER_CSP).toContain("object-src 'none'")
    expect(FILE_RENDERER_CSP).toContain("base-uri 'none'")
    expect(FILE_RENDERER_CSP).toContain("frame-src 'none'")
    expect(FILE_RENDERER_CSP).toContain("form-action 'none'")
    expect(FILE_RENDERER_CSP).toContain("worker-src 'none'")
    expect(FILE_RENDERER_CSP).not.toContain('unsafe-eval')
    expect(FILE_RENDERER_CSP).not.toContain('*')
  })

  it.each(['media', 'clipboard-read', 'notifications', 'openExternal', 'unknown-future'])(
    'denies the %j permission',
    (permission) => {
      expect(isPermissionGranted(permission)).toBe(false)
    }
  )

  it.each([
    ['https://example.com/docs', true],
    ['http://example.com', false],
    ['file:///etc/passwd', false],
    ['javascript:alert(1)', false],
    ['data:text/html,<script></script>', false]
  ])('denies the window-open for %j and only relays https externally', (url, openExternally) => {
    expect(decideWindowOpen(url)).toEqual({ action: 'deny', openExternally })
  })

  it.each(['https://example.com', 'file:///other.html', 'about:blank'])(
    'never allows an in-window navigation to %j',
    (url) => {
      expect(isNavigationAllowed(url)).toBe(false)
    }
  )
})
