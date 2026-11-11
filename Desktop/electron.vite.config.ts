import { execSync } from 'node:child_process'
import { resolve } from 'node:path'
import { defineConfig, externalizeDepsPlugin } from 'electron-vite'
import react from '@vitejs/plugin-react'

// `WP_OUT_DIR=out-x npx electron-vite build` builds into another folder (parallel checks); run it with
// `npx electron out-x/main/index.js`.
const out = resolve(__dirname, process.env.WP_OUT_DIR ?? 'out')

/// The commit the build comes from, shown next to the version (src/main/version.ts). A release build in CI sets
/// WP_GIT_COMMIT before it writes the tag's version into package.json; elsewhere "-dirty" marks uncommitted changes.
function gitCommit(): string {
  if (process.env.WP_GIT_COMMIT) return process.env.WP_GIT_COMMIT
  try {
    const run = (command: string) => execSync(command, { cwd: __dirname, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim()
    const commit = run('git rev-parse --short=7 HEAD')
    return run('git status --porcelain --untracked-files=no') ? `${commit}-dirty` : commit
  } catch {
    return 'unknown'
  }
}

const alias = {
  '@core': resolve(__dirname, 'src/core'),
  '@shared': resolve(__dirname, 'src/shared'),
}

export default defineConfig({
  main: {
    // Runtime dependencies of the main process stay in node_modules (packaged); everything else is bundled.
    plugins: [externalizeDepsPlugin()],
    resolve: { alias },
    define: { __WP_COMMIT__: JSON.stringify(gitCommit()) },
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
    // The UI strings live in the repo's shared translation table (Tools/strings/ru.json).
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
