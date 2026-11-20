import { defineConfig } from '@playwright/test';
export default defineConfig({
  testDir: './tests',
  use: { baseURL: 'http://127.0.0.1:1420', viewport: { width: 1280, height: 800 }, channel: process.env.CI ? undefined : 'chrome' },
  webServer: { command: 'npm run dev', url: 'http://127.0.0.1:1420', reuseExistingServer: false },
});
