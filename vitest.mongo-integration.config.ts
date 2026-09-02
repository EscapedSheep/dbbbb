import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    environment: 'node',
    include: ['src/main/adapters/mongo-adapter.integration.ts'],
    env: {
      DBBBB_MONGO_INTEGRATION_RUNNER: '1'
    },
    hookTimeout: 20_000,
    testTimeout: 20_000,
    restoreMocks: true
  }
})
