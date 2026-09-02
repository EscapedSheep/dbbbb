// @vitest-environment node
import { Buffer } from 'node:buffer'
import { beforeEach, describe, expect, it, vi } from 'vitest'

const defaultSafeStorage = vi.hoisted(() => ({
  isEncryptionAvailable: vi.fn(() => true),
  encryptString: vi.fn((plaintext: string) => Buffer.from(`encrypted:${plaintext}`, 'utf8')),
  decryptString: vi.fn((ciphertext: Buffer) => ciphertext.toString('utf8').replace(/^encrypted:/, '')),
  getSelectedStorageBackend: vi.fn(() => 'gnome_libsecret')
}))

vi.mock('electron', () => ({ safeStorage: defaultSafeStorage }))

import {
  ElectronSafeStorageProtector,
  type SafeStorageLike
} from './electron-safe-storage-protector'

function fakeStorage(options: {
  available?: boolean
  backend?: string
  backendError?: Error
  encryptError?: Error
  decryptError?: Error
} = {}): SafeStorageLike & {
  isEncryptionAvailable: ReturnType<typeof vi.fn>
  encryptString: ReturnType<typeof vi.fn>
  decryptString: ReturnType<typeof vi.fn>
  getSelectedStorageBackend: ReturnType<typeof vi.fn>
} {
  return {
    isEncryptionAvailable: vi.fn(() => options.available ?? true),
    encryptString: vi.fn((plaintext: string) => {
      if (options.encryptError) throw options.encryptError
      return Buffer.from(`cipher:${plaintext}`, 'utf8')
    }),
    decryptString: vi.fn((ciphertext: Buffer) => {
      if (options.decryptError) throw options.decryptError
      return ciphertext.toString('utf8').replace(/^cipher:/, '')
    }),
    getSelectedStorageBackend: vi.fn(() => {
      if (options.backendError) throw options.backendError
      return options.backend ?? 'gnome_libsecret'
    })
  }
}

beforeEach(() => {
  vi.clearAllMocks()
})

describe('ElectronSafeStorageProtector availability', () => {
  it.each([
    ['darwin', 'electron-safe-storage:macos-keychain'],
    ['win32', 'electron-safe-storage:windows-dpapi']
  ] as const)('uses Electron encryption on %s', (platform, backend) => {
    const storage = fakeStorage()
    const protector = new ElectronSafeStorageProtector(storage, platform)

    expect(protector.isAvailable()).toBe(true)
    expect(protector.backend).toBe(backend)
    expect(storage.getSelectedStorageBackend).not.toHaveBeenCalled()
  })

  it.each([
    ['gnome_libsecret', 'electron-safe-storage:linux-gnome-libsecret'],
    ['kwallet', 'electron-safe-storage:linux-kwallet'],
    ['kwallet5', 'electron-safe-storage:linux-kwallet5'],
    ['kwallet6', 'electron-safe-storage:linux-kwallet6']
  ])('accepts the encrypted Linux backend %s', (selected, backend) => {
    const protector = new ElectronSafeStorageProtector(
      fakeStorage({ backend: selected }),
      'linux'
    )

    expect(protector.isAvailable()).toBe(true)
    expect(protector.backend).toBe(backend)
  })

  it.each(['basic_text', 'unknown', '', 'future_unreviewed_backend'])(
    'rejects the Linux backend %j without using the fallback',
    (backend) => {
      const storage = fakeStorage({ backend })
      const protector = new ElectronSafeStorageProtector(storage, 'linux')
      const secret = 'mongodb://user:TOP_SECRET@example.test/app'

      expect(protector.isAvailable()).toBe(false)
      expect(protector.backend).toBe('electron-safe-storage:unavailable')
      expect(() => protector.encrypt(secret)).toThrow('Secure credential storage is unavailable.')
      expect(() => protector.decrypt(Buffer.from('ciphertext'))).toThrow(
        'Secure credential storage is unavailable.'
      )
      expect(storage.encryptString).not.toHaveBeenCalled()
      expect(storage.decryptString).not.toHaveBeenCalled()
    }
  )

  it('rejects Linux when backend detection fails or is absent', () => {
    const failing = fakeStorage({ backendError: new Error('desktop secret') })
    const missing = fakeStorage()
    delete (missing as Partial<SafeStorageLike>).getSelectedStorageBackend

    expect(new ElectronSafeStorageProtector(failing, 'linux').isAvailable()).toBe(false)
    expect(new ElectronSafeStorageProtector(missing, 'linux').isAvailable()).toBe(false)
  })

  it.each(['darwin', 'win32', 'linux'] as const)(
    'requires Electron encryption availability on %s',
    (platform) => {
      const storage = fakeStorage({ available: false })
      const protector = new ElectronSafeStorageProtector(storage, platform)

      expect(protector.isAvailable()).toBe(false)
      expect(protector.backend).toBe('electron-safe-storage:unavailable')
      expect(() => protector.encrypt('DO_NOT_LEAK')).toThrow(
        'Secure credential storage is unavailable.'
      )
      expect(storage.encryptString).not.toHaveBeenCalled()
    }
  )

  it('fails closed on unsupported platforms', () => {
    const storage = fakeStorage()
    const protector = new ElectronSafeStorageProtector(storage, 'freebsd')

    expect(protector.isAvailable()).toBe(false)
    expect(protector.backend).toBe('electron-safe-storage:unavailable')
    expect(storage.isEncryptionAvailable).not.toHaveBeenCalled()
    expect(storage.getSelectedStorageBackend).not.toHaveBeenCalled()
  })

  it('supports the default Electron safeStorage and process platform constructor', () => {
    const protector = new ElectronSafeStorageProtector()
    const supported = process.platform === 'darwin' || process.platform === 'win32' || process.platform === 'linux'

    expect(protector.isAvailable()).toBe(supported)
    if (supported) expect(protector.backend).not.toBe('electron-safe-storage:unavailable')
  })
})

describe('ElectronSafeStorageProtector encryption', () => {
  it('encrypts and decrypts through the selected secure backend', () => {
    const storage = fakeStorage({ backend: 'gnome_libsecret' })
    const protector = new ElectronSafeStorageProtector(storage, 'linux')
    const encrypted = protector.encrypt('secret value')

    expect(Buffer.from(encrypted).toString('utf8')).toBe('cipher:secret value')
    expect(protector.decrypt(encrypted)).toBe('secret value')
    expect(storage.encryptString).toHaveBeenCalledWith('secret value')
    expect(storage.decryptString).toHaveBeenCalledWith(Buffer.from(encrypted))
  })

  it('redacts plaintext and backend error details when encryption fails', () => {
    const secret = 'postgresql://user:PLAINTEXT_SECRET@example.test/app'
    const storage = fakeStorage({ encryptError: new Error(`failed for ${secret}`) })
    const protector = new ElectronSafeStorageProtector(storage, 'darwin')

    let caught: unknown
    try {
      protector.encrypt(secret)
    } catch (error) {
      caught = error
    }

    expect(caught).toBeInstanceOf(Error)
    expect((caught as Error).message).toBe('Secure credential encryption failed.')
    expect((caught as Error).message).not.toContain(secret)
    expect((caught as Error).message).not.toContain('PLAINTEXT_SECRET')
  })

  it('redacts backend error details when decryption fails', () => {
    const storage = fakeStorage({ decryptError: new Error('ciphertext path and secret') })
    const protector = new ElectronSafeStorageProtector(storage, 'win32')

    expect(() => protector.decrypt(Buffer.from('opaque ciphertext'))).toThrow(
      'Secure credential decryption failed.'
    )
  })

  it('rejects empty or malformed backend results with generic errors', () => {
    const storage = fakeStorage()
    storage.encryptString.mockReturnValue(Buffer.alloc(0))
    storage.decryptString.mockReturnValue(undefined)
    const protector = new ElectronSafeStorageProtector(storage, 'darwin')

    expect(() => protector.encrypt('secret')).toThrow('Secure credential encryption failed.')
    expect(() => protector.decrypt(Buffer.from('ciphertext'))).toThrow(
      'Secure credential decryption failed.'
    )
    expect(() => protector.decrypt(new Uint8Array())).toThrow(
      'Secure credential decryption failed.'
    )
  })
})
