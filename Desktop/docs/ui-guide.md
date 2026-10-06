# Waiting Paws for Windows & Web — UI guide

The desktop app is a port of the macOS SwiftUI app (`App/Sources/Mac`, `App/Sources/Views`). Behaviour, texts and
flows follow the Mac app; the *look* deliberately does not. It follows neutral cross-platform desktop conventions
(VS Code, Teams, Discord, Linear) with Windows 11 / Fluent 2 details.

## Structure

```
src/core      platform-free TypeScript port of Packages/WaitingPawsCore (parser, engine, log, go2rtc client…)
src/shared    contract between UI and backend (api.ts), settings, i18n, translations (strings/*.en.json)
src/main      Electron main process = the backend (go2rtc process, recording, files, iPhone link)
src/preload   window.wp bridge (contextIsolation, sandbox)
src/renderer  React UI (web-portable: talks only to window.wp)
```

The UI never touches files or the network directly (except the live camera player and `<img>` snapshots from
go2rtc). It reads `AppState` (zustand: `useApp()`, `useStore(s => s.app…)`) and calls backend methods:
`call('method', ...args)` (errors become a toast) or `callStrict` (throws). The UI's own go2rtc requests (camera
picker, Xiaomi sign-in) go through `new Go2RTCClient(server, { fetch: bridgeFetch })` from
`renderer/src/platform/bridge.ts`. In a plain browser `window.wp` is an in-page backend (`platform/browserBackend.ts`).

## Look

- **Window**: one window; custom title bar (48 px) with the system caption buttons drawn by Windows; left
  navigation rail (Тренировка, История, Настройки); everything else is a page or an in-window dialog.
- **Never**: traffic lights, toolbar pill clusters, sheets, ⌘/⌥/⇧ glyphs (write `Ctrl+Shift+V`), "Finder"
  (say «Показать в проводнике» / "Show in Explorer"), System-Settings sidebars with coloured squircle icons,
  frosted glass cards, radii above 8 px (dialogs 12 px), SF Symbols names in UI.
- **Dialogs**: `Dialog` from `ui/kit.tsx`. Windows button order in the footer: the main action first
  (`variant="primary"`, Enter), other actions, `<span className="spacer" />`, Cancel/Close last (Esc).
- **Menus**: `Menu`/`MenuTrigger`/`MenuContent`/`MenuItem`/`MenuCheckItem`/`SubMenu` (Radix) from `ui/kit.tsx`;
  context menus via `ContextMenu*`.
- **Controls**: `Button` (`variant`: default | primary | subtle | danger | danger-solid | link; `size`: sm | md | lg
  | xl; `icon`, `shortcut="Ctrl+R"`), `Switch` (settings rows), `Checkbox`, `Segmented`, `Tooltip`, `InfoBar`,
  `Spinner`, `Kbd`. Inputs: `<input className="input">`, `<textarea className="textarea">`,
  `<select className="select">`, wrapped in `.field` with `.field__label` / `.field__hint`.
- **Icons**: only from `ui/icons.ts` (Fluent System Icons, 20 px). Add new ones there by meaning
  (`export { Foo20Regular as FooIcon }` — check the name exists in `@fluentui/react-icons`).
- **Tokens**: `styles/tokens.css` — colours only through variables (`--bg-surface`, `--text-secondary`,
  `--accent`, `--accent-text`, `--danger`, `--warning`, `--info`, `--success`, `--phase-*`, `--border-*`), spacing
  `--space-*` (4 px grid), radii `--radius-sm|md|lg|xl`. Dark and light themes must both work.
- **Type**: body 14/20, captions 12/16, headings `.h1` 24, `.h2` 18, `.h3` 14 semibold, section labels
  `.section-title` (11 px caps). Numbers that change: `.tabular`.
- **Classes**: `.card`, `.card--padded`, `.row`, `.col`, `.spacer`, `.grow`, `.ellipsis`, `.muted`, `.faint`,
  `.badge(--accent|info|warning|danger|success)`, `.dot(--live|rec)`, `.empty-state`, `.divider`.
- Each area keeps its CSS in `styles/<area>.css`, imported from the area's main component.

## Texts

- Russian text is the key: `t('Начать выход %lld', n)` (Swift specifiers `%@`, `%lld`, `%.0f`, `%1$@`).
- Reuse the Mac strings verbatim (they are already translated in `Tools/strings/en.json`). New strings: add the
  English to `src/shared/strings/<area>.en.json`. Mac wording that does not fit Windows gets a new key
  ("Показать в Finder" → «Показать в проводнике»).
- Dates/times: `formatTime`, `formatShortDate` from `model.ts`, or `Intl` with `coreLocale()` from
  `@core/localization`; durations: `DurationText.clock / short / compact` from `@core/durationText`.
- Plurals: `plural(n, ['%d выход', '%d выхода', '%d выходов'], ['%d exit', '%d exits'])`.

## Keyboard

Space next step (Outside / Back Inside), Backspace false start (outside or in a break), Ctrl+Enter start, Ctrl+Shift+V paste schedule, Ctrl+Shift+R repeat last,
Ctrl+R record, Ctrl+E finish, Ctrl+1 / Ctrl+H / Ctrl+, pages, F11 full screen. Plan timeline: Ctrl+= / Ctrl+− / Ctrl+0
zoom. Review dialog: Ctrl+N add, Ctrl+D duplicate, Del delete, Alt+↑/↓ move. History: Ctrl+F search, Ctrl+Shift+C
copy the log, Ctrl+Alt+I inspector, Delete, Space play/pause, Enter play. Shortcuts appear in tooltips
("Записать видео (Ctrl+R)") and in buttons via `shortcut`.

## Checking your work

```
source <scratchpad>/env.sh            # portable Node on PATH (development machine)
cd Desktop && npx tsc --noEmit -p tsconfig.web.json && npx electron-vite build
npx electron . --data-dir=<temp folder> --demo-history --demo-plan --capture=<file.png> --quit-after-capture \
  --eval="__wpUI.set({route:'history'})"
```

`--data-dir` keeps everything (settings, history, go2rtc config) in a temporary folder. Demo flags:
`--demo-history`, `--demo-plan`, `--demo-session --demo-exits-done=3 --demo-phase=away`. `--capture` saves a PNG of
the page (without the Mica backdrop and the system caption buttons). `__wpUI` is the UI store
(`__wpUI.set({ reviewingPlan: true })`).
