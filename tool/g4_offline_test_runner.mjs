import { createHash, randomUUID } from 'node:crypto';
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { execFileSync, spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const sdk = path.resolve(process.argv[2] || 'C:/src/flutter');
const sha = value => createHash('sha256').update(value).digest('hex');
const testFiles = ['test/requeue_rpc_contract_test.dart', 'test/mdac_human_evidence_test.dart',
  'test/mdac_human_review_test.dart', 'test/g4_offline_media_boundary_test.dart'];
const protectedFiles = ['lib/mdac_human_evidence.dart', 'lib/supabase_gateway.dart',
  'lib/main.dart', 'lib/main_isolation.dart', 'pubspec.lock'];
const files = [...testFiles, ...protectedFiles, 'test/flutter_test_config.dart', 'tool/g4_offline_test_runner.mjs'];
const hashes = Object.fromEntries(files.map(file => [file, sha(readFileSync(path.join(root, file)))]));
const runId = randomUUID();
const out = path.join(root, 'evidence/20261021/parallel-c');
mkdirSync(out, { recursive: true });
const raw = path.join(out, `app-tests-${runId}.jsonl`);
const command = ['--suppress-analytics', '--no-version-check', 'test', '--no-pub', '--reporter', 'json',
  '--file-reporter', `json:${raw}`, ...testFiles];
const started = new Date().toISOString();
const child = spawn(path.join(sdk, 'bin/cache/dart-sdk/bin/dart.exe'),
  [path.join(sdk, 'bin/cache/flutter_tools.snapshot'), ...command],
  { cwd: root, stdio: ['ignore', 'pipe', 'pipe'] });
const stdout = [], stderr = [];
child.stdout.on('data', bytes => stdout.push(bytes)); child.stderr.on('data', bytes => stderr.push(bytes));
const exit = await new Promise((resolve, reject) => { child.on('error', reject); child.on('exit', resolve); });
const events = readFileSync(raw, 'utf8').trim().split(/\r?\n/).map(line => JSON.parse(line));
const tests = events.filter(row => row.type === 'testDone' && !row.hidden && !row.skipped);
const summary = { run_id: runId, environment: 'LOCAL_OFFLINE_NO_AUTH_OR_UPLOAD', started_at: started,
  finished_at: new Date().toISOString(),
  source_commit: execFileSync('git', ['-c', `safe.directory=${root.replaceAll('\\', '/')}`, 'rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim(),
  source_hashes: hashes, sdk_version: JSON.parse(readFileSync(path.join(sdk, 'bin/cache/flutter.version.json'), 'utf8')),
  command: ['dart', 'flutter_tools.snapshot', ...command.map(value => value.startsWith('json:') ? 'json:<this-run-report.jsonl>' : value)],
  exit_code: exit, passed: tests.filter(row => row.result === 'success').length,
  failed: tests.filter(row => row.result !== 'success').length,
  stdout_sha256: sha(Buffer.concat(stdout)), stderr_sha256: sha(Buffer.concat(stderr)),
  raw_report: path.relative(root, raw).replaceAll('\\', '/'), raw_sha256: sha(readFileSync(raw)),
  product_sources_unchanged: protectedFiles.every(file => hashes[file] === sha(readFileSync(path.join(root, file)))),
  hosted_requests: 0, browser_interactions: 0, android_device_interactions: 0,
  limits: ['RPC calls are test handlers, not real tokens or database execution.',
    'Media tests inspect local synthetic headers/size, not full-file parser, upload finality or physical deletion.',
    'HTTP tripwire rejects Dart HttpClient construction inside the selected test execution zone; it is not OS sandbox attestation.'] };
const target = path.join(out, `app-offline-${runId}.json`);
writeFileSync(target, `${JSON.stringify(summary, null, 2)}\n`, { flag: 'wx' });
console.log(JSON.stringify({ summary: path.relative(root, target), exit, passed: summary.passed, failed: summary.failed }));
if (exit !== 0 || summary.failed || !summary.product_sources_unchanged) process.exitCode = 1;
