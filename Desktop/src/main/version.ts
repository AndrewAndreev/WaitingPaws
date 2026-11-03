import packageInfo from '../../package.json'

/// The commit the build comes from (electron.vite.config.ts). Not defined under vitest.
declare const __WP_COMMIT__: string | undefined

const commit = typeof __WP_COMMIT__ === 'string' ? __WP_COMMIT__ : 'unknown'

/// "1.6.10 (9a8e796)": a release, whose version CI takes from its `v1.6.10` tag (Tools/release.sh), the same as on
/// iPhone and Mac; "dev (9a8e796-dirty)" for any other build: package.json keeps 0.0.0. From package.json at build
/// time, so it is right in development builds started from another folder too.
export const appVersion = packageInfo.version === '0.0.0' ? `dev (${commit})` : `${packageInfo.version} (${commit})`
