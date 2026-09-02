import { join } from 'node:path'
import { writeFile } from 'node:fs/promises'
import { app, BrowserWindow, shell } from 'electron'
import { registerDatabaseIpc } from './database-ipc'
import { DatabaseService } from './database-service'
import { ConnectionVault } from './profiles/connection-vault'
import { ElectronSafeStorageProtector } from './profiles/electron-safe-storage-protector'
import {
  decideWindowOpen,
  FILE_RENDERER_CSP,
  isNavigationAllowed,
  isPermissionGranted
} from './window-security'

let mainWindow: BrowserWindow | null = null
let databaseShutdownStarted = false
let closeDatabaseIpc: (() => void) | undefined
let databaseService: DatabaseService | undefined
let databaseInitialization: Promise<void> | undefined
const SHUTDOWN_WATCHDOG_MS = 5_000

function createWindow(): void {
  if (databaseShutdownStarted) return
  mainWindow = new BrowserWindow({
    width: 1360,
    height: 860,
    minWidth: 980,
    minHeight: 680,
    show: false,
    title: 'dbbbb',
    backgroundColor: '#0d1117',
    titleBarStyle: 'default',
    webPreferences: {
      preload: join(__dirname, '../preload/index.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true
    }
  })

  mainWindow.once('ready-to-show', () => mainWindow?.show())

  mainWindow.webContents.session.setPermissionRequestHandler((_webContents, permission, callback) => {
    callback(isPermissionGranted(permission))
  })
  mainWindow.webContents.session.setPermissionCheckHandler(
    (_webContents, permission) => isPermissionGranted(permission)
  )

  if (app.isPackaged || !process.env.ELECTRON_RENDERER_URL) {
    mainWindow.webContents.session.webRequest.onHeadersReceived(
      { urls: ['file://*/*'] },
      (details, callback) => {
        callback({
          responseHeaders: {
            ...details.responseHeaders,
            'Content-Security-Policy': [FILE_RENDERER_CSP]
          }
        })
      }
    )
  }

  // Screenshot automation is a development aid only; never enable it in packaged builds.
  const screenshotPath = app.isPackaged ? undefined : process.env.DBBBB_SCREENSHOT_PATH
  if (screenshotPath) {
    mainWindow.webContents.once('did-finish-load', async () => {
      if (!mainWindow) return
      const requestedTheme = process.env.DBBBB_SCREENSHOT_THEME === 'dark' ? 'dark' : 'light'
      await new Promise((resolve) => setTimeout(resolve, 250))
      await mainWindow.webContents.executeJavaScript(`
        document.documentElement.dataset.theme = ${JSON.stringify(requestedTheme)};
        document.documentElement.style.colorScheme = ${JSON.stringify(requestedTheme)};
      `)
      if (process.env.DBBBB_SCREENSHOT_DIALOG === 'connection') {
        await mainWindow.webContents.executeJavaScript(
          `document.querySelector('[aria-label="New connection"]')?.click()`
        )
        await new Promise((resolve) => setTimeout(resolve, 180))
        if (process.env.DBBBB_SCREENSHOT_ENGINE === 'mongodb') {
          await mainWindow.webContents.executeJavaScript(
            `document.querySelectorAll('.engine-option')[1]?.click()`
          )
          await new Promise((resolve) => setTimeout(resolve, 100))
        }
      } else if (process.env.DBBBB_SCREENSHOT_ENGINE === 'mongodb') {
        await mainWindow.webContents.executeJavaScript(
          `document.querySelectorAll('.connection-item')[1]?.click()`
        )
        await new Promise((resolve) => setTimeout(resolve, 180))
      }
      if (process.env.DBBBB_SCREENSHOT_DIALOG !== 'connection') {
        await mainWindow.webContents.executeJavaScript(`document.querySelector('.run-button')?.click()`)
        await new Promise((resolve) => setTimeout(resolve, 350))
      }
      if (process.env.DBBBB_SCREENSHOT_DIALOG === 'library') {
        await mainWindow.webContents.executeJavaScript(
          `document.querySelector('[aria-label^="Open query library"]')?.click()`
        )
        await new Promise((resolve) => setTimeout(resolve, 150))
      }
      if (process.env.DBBBB_SCREENSHOT_DIALOG === 'import') {
        await mainWindow.webContents.executeJavaScript(`document.querySelector('.tree-root')?.click()`)
        await new Promise((resolve) => setTimeout(resolve, 80))
        await mainWindow.webContents.executeJavaScript(`document.querySelector('.tree-child')?.click()`)
        await new Promise((resolve) => setTimeout(resolve, 100))
        await mainWindow.webContents.executeJavaScript(`
          const button = document.querySelector('.import-button');
          if (button) { button.disabled = false; button.click(); }
        `)
        await new Promise((resolve) => setTimeout(resolve, 120))
      }
      const image = await mainWindow.webContents.capturePage()
      await writeFile(screenshotPath, image.toPNG())
      app.quit()
    })
  }

  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    const decision = decideWindowOpen(url)
    if (decision.openExternally) {
      void shell.openExternal(url)
    }
    return { action: decision.action }
  })

  mainWindow.webContents.on('will-navigate', (event) => {
    if (!isNavigationAllowed(event.url)) event.preventDefault()
  })

  if (!app.isPackaged && process.env.ELECTRON_RENDERER_URL) {
    void mainWindow.loadURL(process.env.ELECTRON_RENDERER_URL)
  } else {
    void mainWindow.loadFile(join(__dirname, '../renderer/index.html'))
  }

  mainWindow.on('closed', () => {
    mainWindow = null
  })
}

// Only this process may write the connection vault; refuse a second instance
// so two processes can never race a vault write.
const hasSingleInstanceLock = app.requestSingleInstanceLock()
if (!hasSingleInstanceLock) {
  app.quit()
}

app.on('second-instance', () => {
  if (!mainWindow) return
  if (mainWindow.isMinimized()) mainWindow.restore()
  mainWindow.focus()
})

void app.whenReady().then(async () => {
  if (!hasSingleInstanceLock || databaseShutdownStarted) return
  const vault = new ConnectionVault(
    join(app.getPath('userData'), 'connections.vault.json'),
    new ElectronSafeStorageProtector()
  )
  const service = new DatabaseService(vault)
  databaseService = service
  databaseInitialization = service.initialize()
  await databaseInitialization
  if (databaseShutdownStarted) return

  closeDatabaseIpc = registerDatabaseIpc(service, () => mainWindow)
  createWindow()

  app.on('activate', () => {
    if (!databaseShutdownStarted && BrowserWindow.getAllWindows().length === 0) {
      createWindow()
    }
  })
}).catch(() => {
  if (!databaseShutdownStarted) app.quit()
})

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit()
  }
})

app.on('before-quit', (event) => {
  if (databaseShutdownStarted) return
  databaseShutdownStarted = true
  event.preventDefault()
  closeDatabaseIpc?.()
  const shutdown = (async () => {
    await databaseInitialization?.catch(() => undefined)
    await databaseService?.closeAll()
  })()
  // A hung driver close must not trap the process; quit when the watchdog fires.
  const watchdog = new Promise<void>((resolve) => {
    setTimeout(resolve, SHUTDOWN_WATCHDOG_MS).unref()
  })
  void Promise.race([shutdown, watchdog]).finally(() => app.quit())
})
