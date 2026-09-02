import { join } from 'node:path'
import { writeFile } from 'node:fs/promises'
import { app, BrowserWindow, shell } from 'electron'
import { CLI_USAGE, parseCliArgs } from './cli'
import type { CliAction } from './cli'
import { registerDatabaseIpc } from './database-ipc'
import { DatabaseService } from './database-service'
import { ConnectionVault } from './profiles/connection-vault'
import { ElectronSafeStorageProtector } from './profiles/electron-safe-storage-protector'
import { IPC_CHANNELS } from '../shared/database'
import type { ConnectionInput, StartupAction } from '../shared/database'
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
let pendingStartupAction: StartupAction | undefined
const SHUTDOWN_WATCHDOG_MS = 5_000

function deliverPendingStartupAction(): void {
  const action = pendingStartupAction
  if (!mainWindow || !action) return
  if (mainWindow.webContents.isLoading()) {
    mainWindow.webContents.once('did-finish-load', deliverPendingStartupAction)
    return
  }
  pendingStartupAction = undefined
  mainWindow.webContents.send(IPC_CHANNELS.startupAction, action)
}

function sendStartupAction(action: StartupAction): void {
  pendingStartupAction = action
  if (mainWindow) deliverPendingStartupAction()
  else createWindow()
}

function focusMainWindow(): void {
  if (!mainWindow) return
  if (mainWindow.isMinimized()) mainWindow.restore()
  mainWindow.focus()
}

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

  mainWindow.webContents.once('did-finish-load', deliverPendingStartupAction)

  mainWindow.on('closed', () => {
    mainWindow = null
  })
}

// Packaged builds put user arguments right after the executable path; dev
// runs add the electron-vite entry point as a second argv entry.
const cliResult = parseCliArgs(process.argv.slice(app.isPackaged ? 1 : 2))
const cliAction: CliAction | undefined =
  cliResult && 'action' in cliResult ? cliResult.action : undefined

// Help and parse errors exit without starting the app; the exit is deferred
// to the stream flush callback so the message is not truncated.
const cliExitsImmediately = Boolean(
  (cliResult && 'error' in cliResult) || cliAction?.kind === 'help'
)

if (cliResult && 'error' in cliResult) {
  process.stderr.write(`${cliResult.error}\n\n${CLI_USAGE}\n`, () => app.exit(1))
} else if (cliAction?.kind === 'help') {
  process.stdout.write(`${CLI_USAGE}\n`, () => app.exit(0))
}

// Only this process may write the connection vault; refuse a second instance
// so two processes can never race a vault write.
const hasSingleInstanceLock = app.requestSingleInstanceLock()
if (!hasSingleInstanceLock) {
  // The running instance receives and executes these arguments instead.
  if (cliAction) process.stdout.write('forwarded to running dbbbb instance\n')
  app.quit()
}

function addConnectionFromCli(input: ConnectionInput): void {
  const service = databaseService
  if (!service) {
    process.stderr.write('add failed: the database service is not ready yet.\n')
    return
  }
  void service.connect(input).then(
    () => sendStartupAction({ kind: 'refresh' }),
    (error: unknown) => {
      const message = error instanceof Error ? error.message : 'The connection failed.'
      process.stderr.write(`add failed: ${message}\n`)
    }
  )
}

app.on('second-instance', (_event, commandLine) => {
  const result = parseCliArgs(commandLine.slice(app.isPackaged ? 1 : 2))
  if (result && 'error' in result) {
    process.stderr.write(`${result.error}\n`)
    return
  }
  const action = result && 'action' in result ? result.action : undefined
  if (!action || action.kind === 'help' || action.kind === 'open') {
    focusMainWindow()
    if (action?.kind === 'open' && action.connection) {
      sendStartupAction({ kind: 'open', connection: action.connection })
    }
    return
  }
  if (action.kind === 'add') {
    addConnectionFromCli(action.input)
    return
  }
  focusMainWindow()
  sendStartupAction({ kind: 'query', connection: action.connection, command: action.command })
})

void app.whenReady().then(async () => {
  if (!hasSingleInstanceLock || databaseShutdownStarted || cliExitsImmediately) return
  const vault = new ConnectionVault(
    join(app.getPath('userData'), 'connections.vault.json'),
    new ElectronSafeStorageProtector()
  )
  const service = new DatabaseService(vault)
  databaseService = service
  databaseInitialization = service.initialize()
  await databaseInitialization
  if (databaseShutdownStarted) return

  if (cliAction?.kind === 'add') {
    // A CLI add only touches the vault; no window is created.
    try {
      const profile = await service.connect(cliAction.input)
      process.stdout.write(`added ${profile.name} (${profile.id})\n`, () => app.exit(0))
    } catch (error) {
      const message = error instanceof Error ? error.message : 'The connection failed.'
      process.stderr.write(`add failed: ${message}\n`, () => app.exit(1))
    }
    return
  }

  closeDatabaseIpc = registerDatabaseIpc(service, () => mainWindow)
  // A second-instance action may already have created the window.
  if (!mainWindow) createWindow()
  if (cliAction?.kind === 'open' && cliAction.connection) {
    sendStartupAction({ kind: 'open', connection: cliAction.connection })
  } else if (cliAction?.kind === 'query') {
    sendStartupAction({
      kind: 'query',
      connection: cliAction.connection,
      command: cliAction.command
    })
  }

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
