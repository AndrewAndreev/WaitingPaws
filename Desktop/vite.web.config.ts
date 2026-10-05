import { resolve } from 'node:path'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// The UI as a web page (no Electron): `npm run web` serves it, `npm run build:web` writes dist-web/. Without the
// desktop backend it runs on the in-page one (platform/browserBackend.ts): schedule, timers, log and history.
export default defineConfig({
  root: resolve(__dirname, 'src/renderer'),
  base: './',
  resolve: {
    alias: {
      '@core': resolve(__dirname, 'src/core'),
      '@shared': resolve(__dirname, 'src/shared'),
      '@renderer': resolve(__dirname, 'src/renderer/src'),
    },
  },
  plugins: [react()],
  server: { port: 5199, strictPort: true, fs: { allow: [resolve(__dirname, '..')] } },
  build: {
    outDir: resolve(__dirname, 'dist-web'),
    emptyOutDir: true,
    rollupOptions: { input: { index: resolve(__dirname, 'src/renderer/index.html') } },
  },
})
