import { resolve } from 'node:path'
import { defineConfig, externalizeDepsPlugin } from 'electron-vite'
import react from '@vitejs/plugin-react'

// `WP_OUT_DIR=out-x npx electron-vite build` builds into another folder (parallel checks); run it with
// `npx electron out-x/main/index.js`.
const out = resolve(__dirname, process.env.WP_OUT_DIR ?? 'out')

const alias = {
  '@core': resolve(__dirname, 'src/core'),
  '@shared': resolve(__dirname, 'src/shared'),
}

export default defineConfig({
  main: {
    // Runtime dependencies of the main process stay in node_modules (packaged); everything else is bundled.
    plugins: [externalizeDepsPlugin()],
    resolve: { alias },
    build: { outDir: resolve(out, 'main') },
  },
  preload: {
    plugins: [externalizeDepsPlugin()],
    resolve: { alias },
    build: {
      outDir: resolve(out, 'preload'),
      rollupOptions: {
        input: {
          index: resolve(__dirname, 'src/preload/index.ts'),
          media: resolve(__dirname, 'src/preload/media.ts'),
        },
        output: { format: 'cjs', entryFileNames: '[name].js' },
      },
    },
  },
  renderer: {
    root: resolve(__dirname, 'src/renderer'),
    resolve: { alias: { ...alias, '@renderer': resolve(__dirname, 'src/renderer/src') } },
    plugins: [react()],
    // The UI strings live in the repo's shared translation table (Tools/strings/en.json).
    server: { fs: { allow: [resolve(__dirname, '..')] } },
    build: {
      outDir: resolve(out, 'renderer'),
      rollupOptions: {
        input: {
          index: resolve(__dirname, 'src/renderer/index.html'),
          media: resolve(__dirname, 'src/renderer/media.html'),
        },
      },
    },
  },
})
