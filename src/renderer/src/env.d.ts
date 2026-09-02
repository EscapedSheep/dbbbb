/// <reference types="vite/client" />

import type { DbbbbApi } from '../../shared/database'

declare global {
  interface Window {
    dbbbb: DbbbbApi
  }
}

export {}

