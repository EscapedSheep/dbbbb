import { Buffer } from 'node:buffer'
import { safeStorage } from 'electron'
import type { Protector } from './connection-vault'

export interface SafeStorageLike {
  isEncryptionAvailable(): boolean
  encryptString(plaintext: string): Buffer
  decryptString(ciphertext: Buffer): string
  getSelectedStorageBackend?(): string
}

const UNAVAILABLE_BACKEND = 'electron-safe-storage:unavailable'

const linuxBackends = new Map<string, string>([
  ['gnome_libsecret', 'electron-safe-storage:linux-gnome-libsecret'],
  ['kwallet', 'electron-safe-storage:linux-kwallet'],
  ['kwallet5', 'electron-safe-storage:linux-kwallet5'],
  ['kwallet6', 'electron-safe-storage:linux-kwallet6']
])

interface Availability {
  available: boolean
  backend: string
}

/**
 * Adapts Electron safeStorage to the vault Protector contract without accepting
 * Electron's Linux `basic_text` fallback as credential encryption.
 */
export class ElectronSafeStorageProtector implements Protector {
  constructor(
    private readonly storage: SafeStorageLike = safeStorage,
    private readonly platform: NodeJS.Platform = process.platform
  ) {}

  get backend(): string {
    return this.availability().backend
  }

  isAvailable(): boolean {
    return this.availability().available
  }

  encrypt(plaintext: string): Uint8Array {
    if (!this.isAvailable()) {
      throw new Error('Secure credential storage is unavailable.')
    }

    try {
      const encrypted = this.storage.encryptString(plaintext)
      if (!(encrypted instanceof Uint8Array) || encrypted.byteLength === 0) {
        throw new Error('Invalid encryption result.')
      }
      return Uint8Array.from(encrypted)
    } catch {
      throw new Error('Secure credential encryption failed.')
    }
  }

  decrypt(ciphertext: Uint8Array): string {
    if (!this.isAvailable()) {
      throw new Error('Secure credential storage is unavailable.')
    }

    try {
      if (!(ciphertext instanceof Uint8Array) || ciphertext.byteLength === 0) {
        throw new Error('Invalid encrypted data.')
      }
      const plaintext = this.storage.decryptString(Buffer.from(ciphertext))
      if (typeof plaintext !== 'string') throw new Error('Invalid decryption result.')
      return plaintext
    } catch {
      throw new Error('Secure credential decryption failed.')
    }
  }

  private availability(): Availability {
    if (this.platform === 'linux') {
      const backend = this.selectedLinuxBackend()
      if (!backend) return { available: false, backend: UNAVAILABLE_BACKEND }
      return this.electronEncryptionAvailable()
        ? { available: true, backend }
        : { available: false, backend: UNAVAILABLE_BACKEND }
    }

    if (this.platform === 'darwin') {
      return this.electronEncryptionAvailable()
        ? { available: true, backend: 'electron-safe-storage:macos-keychain' }
        : { available: false, backend: UNAVAILABLE_BACKEND }
    }

    if (this.platform === 'win32') {
      return this.electronEncryptionAvailable()
        ? { available: true, backend: 'electron-safe-storage:windows-dpapi' }
        : { available: false, backend: UNAVAILABLE_BACKEND }
    }

    return { available: false, backend: UNAVAILABLE_BACKEND }
  }

  private electronEncryptionAvailable(): boolean {
    try {
      return this.storage.isEncryptionAvailable() === true
    } catch {
      return false
    }
  }

  private selectedLinuxBackend(): string | undefined {
    try {
      const selected = this.storage.getSelectedStorageBackend?.()
      if (typeof selected !== 'string') return undefined
      return linuxBackends.get(selected.trim().toLowerCase())
    } catch {
      return undefined
    }
  }
}
