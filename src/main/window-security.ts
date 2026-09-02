export const FILE_RENDERER_CSP = [
  "default-src 'self'",
  "script-src 'self'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data:",
  "connect-src 'none'",
  "object-src 'none'",
  "base-uri 'none'",
  "frame-src 'none'",
  "form-action 'none'",
  "worker-src 'none'"
].join('; ')

export interface WindowOpenDecision {
  action: 'deny'
  openExternally: boolean
}

export function isPermissionGranted(_permission: string): boolean {
  return false
}

export function decideWindowOpen(url: string): WindowOpenDecision {
  return { action: 'deny', openExternally: url.startsWith('https://') }
}

export function isNavigationAllowed(_url: string): boolean {
  return false
}
