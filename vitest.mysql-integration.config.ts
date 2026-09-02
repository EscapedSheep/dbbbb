import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    environment: 'node',
    include: ['src/main/adapters/mysql-adapter.integration.ts'],
    hookTimeout: 20_000,
    testTimeout: 20_000,
    restoreMocks: true
  }
})
