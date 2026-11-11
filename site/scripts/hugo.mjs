import { spawnSync } from 'node:child_process';
import { delimiter, dirname } from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const env = { ...process.env };

// Hugo needs the native embedded protocol, which the JavaScript sass CLI lacks.
if (!env.DART_SASS_BINARY) {
  const musl = process.platform === 'linux' && !process.report.getReport().header.glibcVersionRuntime;
  const platform = `${process.platform}${musl ? '-musl' : ''}`;
  const executable = process.platform === 'win32' ? 'sass.bat' : 'sass';
  const binary = require.resolve(
    `sass-embedded-${platform}-${process.arch}/dart-sass/${executable}`,
  );
  // Hugo rejects any executable path containing "embedded" as an old protocol.
  env.PATH = `${dirname(binary)}${delimiter}${env.PATH ?? ''}`;
  env.DART_SASS_BINARY = executable;
}

// Keep PostCSS's production purge enabled for the default Hugo build.
if (!env.HUGO_ENVIRONMENT) {
  const args = process.argv.slice(2);
  const index = args.indexOf('--environment');
  const environment = index >= 0 ? args[index + 1] : args.find((arg) => arg.startsWith('--environment='))?.split('=')[1];
  env.HUGO_ENVIRONMENT = environment || (args[0] === 'server' ? 'development' : 'production');
}

const result = spawnSync('hugo', process.argv.slice(2), {
  cwd: fileURLToPath(new URL('../', import.meta.url)),
  env,
  stdio: 'inherit',
});
if (result.error) {
  console.error(result.error.message);
}
process.exit(result.status ?? 1);
