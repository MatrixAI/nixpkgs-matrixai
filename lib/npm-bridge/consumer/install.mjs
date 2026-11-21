#!/usr/bin/env node

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { spawn, spawnSync } from 'node:child_process';
import { isDeepStrictEqual } from 'node:util';

const [npm, flock, planPath, ...args] = process.argv.slice(2);
const plan = JSON.parse(fs.readFileSync(planPath, 'utf8'));
const sections = ['dependencies', 'devDependencies', 'optionalDependencies'];
const commands = new Set([
  'install',
  'i',
  'add',
  'ci',
  'update',
  'up',
  'upgrade',
  'uninstall',
  'un',
  'remove',
  'rm',
  'prune',
  'dedupe',
  'ddp',
]);

async function run(command, argv, env = process.env) {
  const child = spawn(command, argv, { stdio: 'inherit', env });
  const signals = ['SIGINT', 'SIGTERM', 'SIGHUP'].map((signal) => [
    signal,
    () => child.kill(signal),
  ]);
  for (const [signal, forward] of signals) process.on(signal, forward);
  try {
    return await new Promise((resolve, reject) => {
      child.once('error', reject);
      child.once('exit', (code, signal) => {
        resolve(code ?? 128 + os.constants.signals[signal]);
      });
    });
  } finally {
    for (const [signal, forward] of signals) process.off(signal, forward);
  }
}

function isArchive(spec, root, archive) {
  return (
    typeof spec === 'string' &&
    spec.startsWith('file:') &&
    path.resolve(root, decodeURIComponent(spec.slice(5))) === archive
  );
}

function validGitOverride(spec, source) {
  const declared = /^(git\+(?:ssh|https|file):\/\/[^?#]+)#semver:([~^])(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.exec(spec);
  const resolved = /^(git\+(?:ssh|https|file):\/\/[^?#]+)#(?:[0-9a-f]{40}|[0-9a-f]{64})$/.exec(source.locked.resolved);
  const version = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.exec(source.locked.version);
  if (declared == null || resolved == null || version == null || declared[1] !== resolved[1]) return false;
  const [major, minor, patch] = declared.slice(3).map(Number);
  const [actualMajor, actualMinor, actualPatch] = version.slice(1).map(Number);
  const atLeast = actualMajor > major || (actualMajor === major && (actualMinor > minor || (actualMinor === minor && actualPatch >= patch)));
  return atLeast && actualMajor === major && (declared[2] === '~' ? actualMinor === minor : major > 0 || (actualMinor === minor && (minor > 0 || actualPatch === patch)));
}

function writeJSON(file, value, original) {
  const text = isDeepStrictEqual(value, JSON.parse(original))
    ? original
    : `${JSON.stringify(value, null, 2)}\n`;
  if (fs.readFileSync(file, 'utf8') !== text) fs.writeFileSync(file, text);
}

function restoreUnchangedMtime(file, original, stat) {
  // Temporary archive rewrites should not invalidate source-plan watchers.
  if (
    fs.readFileSync(file, 'utf8') === original &&
    fs.statSync(file).mtimeMs !== stat.mtimeMs
  ) {
    fs.utimesSync(file, stat.atime, stat.mtime);
  }
}

function requireNoRecovery(root) {
  const recovery = fs
    .readdirSync(path.join(root, 'tmp'))
    .filter((name) => name.startsWith('npm-manifests-'));
  if (recovery.length > 0) {
    throw new Error(
      `Recover manifests from ${path.join(root, 'tmp', recovery[0])} before installing again`,
    );
  }
}

async function refreshLock(root) {
  requireNoRecovery(root);
  const files = ['package.json', 'package-lock.json'];
  const originalStats = files.map((file) => fs.statSync(path.join(root, file)));
  const originals = files.map((file) =>
    fs.readFileSync(path.join(root, file), 'utf8'),
  );
  const backup = fs.mkdtempSync(path.join(root, 'tmp/npm-manifests-'));
  files.forEach((file, index) =>
    fs.writeFileSync(path.join(backup, file), originals[index]),
  );
  let succeeded = false;
  try {
    const result = await run(npm, args, {
      ...process.env,
      MATRIXAI_NPM_INSTALL_ACTIVE: root,
    });
    if (result !== 0) return result;
    if (fs.readFileSync(path.join(root, files[0]), 'utf8') !== originals[0]) {
      throw new Error('Lock refresh unexpectedly changed the package manifest');
    }
    JSON.parse(fs.readFileSync(path.join(root, files[1]), 'utf8'));
    succeeded = true;
    return 0;
  } finally {
    if (!succeeded) {
      files.forEach((file, index) =>
        fs.writeFileSync(path.join(root, file), originals[index]),
      );
    }
    files.forEach((file, index) =>
      restoreUnchangedMtime(path.join(root, file), originals[index], originalStats[index]),
    );
    fs.rmSync(backup, { recursive: true });
  }
}

async function install(root) {
  requireNoRecovery(root);
  const files = ['package.json', 'package-lock.json'];
  const originalStats = files.map((file) => fs.statSync(path.join(root, file)));
  const originals = files.map((file) =>
    fs.readFileSync(path.join(root, file), 'utf8'),
  );
  const [manifest, lock] = originals.map((text) => JSON.parse(text));
  const sources = Object.entries(plan.sources);
  const isGit = (value) =>
    typeof value === 'string' && /^(?:git|github:)/.test(value);
  for (const [modulePath, module] of Object.entries(lock.packages)) {
    if (isGit(module.resolved) && plan.sources[modulePath] == null) {
      throw new Error(
        `${modulePath}: no prepared archive in the current source plan; refresh the lock and reload the shell`,
      );
    }
  }
  for (const section of sections) {
    for (const [name, spec] of Object.entries(manifest[section] ?? {})) {
      if (isGit(spec) && plan.sources[`node_modules/${name}`] == null) {
        throw new Error(
          `${name}: no prepared archive in the current source plan; refresh the lock and reload the shell`,
        );
      }
    }
  }
  if (
    ['install', 'i', 'add'].includes(args[0]) &&
    args.some((arg) => isGit(arg) || /@(?:git|github:)/.test(arg))
  ) {
    throw new Error(
      'Add Git dependencies to the manifest, refresh the lock, and reload the shell before installing',
    );
  }
  for (const [modulePath, source] of sources) {
    const locked = lock.packages[modulePath];
    if (
      locked?.resolved !== source.locked.resolved ||
      locked?.version !== source.locked.version
    ) {
      throw new Error(
        `${source.name}: source pin changed; reload the Nix shell before installing`,
      );
    }
    for (const key of [
      'dependencies',
      'peerDependencies',
      'peerDependenciesMeta',
      'optionalDependencies',
      'engines',
      'bin',
    ]) {
      if (!isDeepStrictEqual(locked[key], source.locked[key])) {
        throw new Error(
          `${source.name}: locked metadata changed; reload the Nix shell before installing`,
        );
      }
    }
    if (modulePath === `node_modules/${source.name}`) {
      for (const section of sections) {
        if (
          manifest[section]?.[source.name] !==
          lock.packages[''][section]?.[source.name]
        ) {
          throw new Error(
            `${source.name}: manifest and lock selection differ; resolve the new source pin before prepared installation`,
          );
        }
      }
    }
  }

  const patchedManifest = structuredClone(manifest);
  const patchedLock = structuredClone(lock);
  const rewrittenEdges = [];
  const rewrittenOverrides = [];
  function rewriteOverrides(overrides, parent = '', keys = []) {
    for (const [selector, value] of Object.entries(overrides)) {
      const target = selector === '.' ? parent : selector;
      const currentKeys = [...keys, selector];
      if (value != null && typeof value === 'object' && !Array.isArray(value)) {
        rewriteOverrides(value, target, currentKeys);
      } else if (typeof value === 'string' && /^(?:git|github:)/.test(value)) {
        const candidates = sources.filter(
          ([, source]) =>
            target === source.name || target.startsWith(`${source.name}@`),
        );
        if (candidates.length !== 1) {
          throw new Error(
            `Git override ${target} requires exactly one prepared locked instance; found ${candidates.length}`,
          );
        }
        if (!validGitOverride(value, candidates[0][1])) {
          throw new Error(
            `Git override ${target} must use a supported semver range satisfied by the locked version and the same source URL`,
          );
        }
        const replacement = `file:${candidates[0][1].archive}`;
        overrides[selector] = replacement;
        rewrittenOverrides.push({ keys: currentKeys, value, replacement });
      }
    }
  }
  if (patchedManifest.overrides != null) {
    rewriteOverrides(patchedManifest.overrides);
  }
  // Resolve each dependency from its own package scope. A nested copy of the
  // same name need not select the top-level producer.
  function selectedSource(modulePath, name) {
    let scope = modulePath;
    while (true) {
      const candidate =
        scope === '' ? `node_modules/${name}` : `${scope}/node_modules/${name}`;
      if (lock.packages[candidate] != null) {
        return plan.sources[candidate];
      }
      if (scope === '') return undefined;
      const parent = scope.lastIndexOf('/node_modules/');
      scope = parent < 0 ? '' : scope.slice(0, parent);
    }
  }
  for (const [modulePath, module] of Object.entries(patchedLock.packages)) {
    if (modulePath === '') continue;
    for (const section of sections) {
      for (const [name, spec] of Object.entries(module[section] ?? {})) {
        if (!/^(?:git|github:)/.test(spec)) continue;
        const source = selectedSource(modulePath, name);
        if (source == null) continue;
        // Only the install-time constraint changes. The locked resolution still
        // selects the reviewed archive; no producer manifest is rewritten.
        module[section][name] = source.locked.version;
        rewrittenEdges.push({ modulePath, section, name, spec });
      }
    }
  }
  for (const [modulePath, source] of sources) {
    const spec = `file:${source.archive}`;
    patchedLock.packages[modulePath].resolved = spec;
    delete patchedLock.packages[modulePath].integrity;
    if (modulePath === `node_modules/${source.name}`) {
      for (const section of sections) {
        if (patchedManifest[section]?.[source.name] != null) {
          patchedManifest[section][source.name] = spec;
          patchedLock.packages[''][section][source.name] = spec;
        }
      }
    }
  }

  const npmArgs = args.map((arg) => {
    for (const [, source] of sources) {
      if (arg === source.name && ['install', 'i', 'add'].includes(args[0])) {
        return `${source.name}@file:${source.archive}`;
      }
      if (arg.startsWith(`${source.name}@`)) {
        throw new Error(
          `Change ${source.name}'s canonical pin and reload the shell to select another producer revision`,
        );
      }
    }
    return arg;
  });
  // Keep recovery copies on disk if the process is killed without cleanup.
  const backup = fs.mkdtempSync(path.join(root, 'tmp/npm-manifests-'));
  files.forEach((file, index) =>
    fs.writeFileSync(path.join(backup, file), originals[index]),
  );
  let result = 1;
  try {
    writeJSON(path.join(root, files[0]), patchedManifest, originals[0]);
    writeJSON(path.join(root, files[1]), patchedLock, originals[1]);
    result = await run(npm, npmArgs, {
      ...process.env,
      MATRIXAI_NPM_INSTALL_ACTIVE: root,
    });
  } finally {
    try {
      const current =
        result === 0
          ? files.map((file) =>
              JSON.parse(fs.readFileSync(path.join(root, file), 'utf8')),
            )
          : [manifest, lock];
      const [nextManifest, nextLock] = current;
      for (const { keys, value, replacement } of rewrittenOverrides) {
        let target = nextManifest.overrides;
        for (const key of keys.slice(0, -1)) target = target?.[key];
        const key = keys.at(-1);
        if (target?.[key] === replacement) target[key] = value;
      }
      for (const { modulePath, section, name, spec } of rewrittenEdges) {
        const module = nextLock.packages[modulePath];
        if (
          module?.[section]?.[name] ===
          patchedLock.packages[modulePath][section][name]
        ) {
          module[section][name] = spec;
        }
      }
      for (const [modulePath, source] of sources) {
        if (
          isArchive(
            nextLock.packages[modulePath]?.resolved,
            root,
            source.archive,
          )
        ) {
          nextLock.packages[modulePath].resolved = source.locked.resolved;
          if (source.locked.integrity == null) {
            delete nextLock.packages[modulePath].integrity;
          } else {
            nextLock.packages[modulePath].integrity = source.locked.integrity;
          }
        }
        for (const section of sections) {
          if (
            isArchive(
              nextManifest[section]?.[source.name],
              root,
              source.archive,
            )
          ) {
            nextManifest[section][source.name] =
              manifest[section]?.[source.name] ??
              manifest.dependencies?.[source.name] ??
              manifest.devDependencies?.[source.name] ??
              manifest.optionalDependencies?.[source.name];
          }
          if (
            isArchive(
              nextLock.packages[''][section]?.[source.name],
              root,
              source.archive,
            )
          ) {
            nextLock.packages[''][section][source.name] =
              nextManifest[section][source.name];
          }
        }
      }
      for (const source of Object.values(plan.sources)) {
        JSON.stringify(current, (_, value) => {
          if (isArchive(value, root, source.archive)) {
            throw new Error(`Unrestored archive reference for ${source.name}`);
          }
          return value;
        });
      }
      files.forEach((file, index) =>
        writeJSON(path.join(root, file), current[index], originals[index]),
      );
      files.forEach((file, index) =>
        restoreUnchangedMtime(path.join(root, file), originals[index], originalStats[index]),
      );
      fs.rmSync(backup, { recursive: true });
    } catch (error) {
      for (const file of files) {
        fs.copyFileSync(
          path.join(root, file),
          path.join(backup, `${file}.attempt`),
        );
      }
      files.forEach((file, index) =>
        fs.writeFileSync(path.join(root, file), originals[index]),
      );
      files.forEach((file, index) =>
        restoreUnchangedMtime(path.join(root, file), originals[index], originalStats[index]),
      );
      // A recovery failure takes precedence over an interrupted installation.
      // eslint-disable-next-line no-unsafe-finally
      throw new Error(`Manifest recovery copies retained at ${backup}`, {
        cause: error,
      });
    }
  }
  return result;
}

async function main() {
  const locked = args[0] === '--nix-npm-locked';
  if (locked) args.shift();
  const refresh =
    ['install', 'i', 'update', 'up', 'upgrade'].includes(args[0]) &&
    args.some((arg) =>
      ['--package-lock-only', '--package-lock-only=true'].includes(arg),
    );
  if (refresh && args.includes('--ignore-scripts=false')) {
    throw new Error('Lock refresh requires --ignore-scripts');
  }
  if (refresh && !args.includes('--ignore-scripts')) {
    args.push('--ignore-scripts');
  }
  if (
    !commands.has(args[0]) ||
    args.some((arg) => arg === '-g' || arg === '--global')
  ) {
    return run(npm, args);
  }
  const locationArgs = args.filter(
    (arg, index) =>
      arg.startsWith('--prefix=') ||
      arg === '--prefix' ||
      args[index - 1] === '--prefix',
  );
  const prefix = spawnSync(npm, ['prefix', ...locationArgs], {
    encoding: 'utf8',
  });
  if (prefix.status !== 0) {
    throw new Error(prefix.stderr || 'Unable to locate npm project');
  }
  const root = prefix.stdout.trim();
  if (!fs.existsSync(path.join(root, 'package.json'))) return run(npm, args);
  const manifest = JSON.parse(
    fs.readFileSync(path.join(root, 'package.json'), 'utf8'),
  );
  if (manifest.name !== plan.packageName) return run(npm, args);
  if (fs.existsSync(path.join(root, 'npm-shrinkwrap.json'))) {
    throw new Error(
      'Prepared installation currently requires package-lock.json, not npm-shrinkwrap.json',
    );
  }
  if (process.env.MATRIXAI_NPM_INSTALL_ACTIVE === root) {
    throw new Error(
      'Recursive npm installation in a lifecycle script is not supported',
    );
  }
  if (locked) return refresh ? refreshLock(root) : install(root);
  fs.mkdirSync(path.join(root, 'tmp'), { recursive: true });
  return run(flock, [
    '--exclusive',
    '--no-fork',
    path.join(root, 'tmp/npm-install.lock'),
    process.execPath,
    process.argv[1],
    npm,
    flock,
    planPath,
    '--nix-npm-locked',
    ...args,
  ]);
}

try {
  process.exitCode = await main();
} catch (error) {
  process.stderr.write(`${error.stack ?? error}\n`);
  if (error.cause != null) {
    process.stderr.write(`Caused by: ${error.cause.stack ?? error.cause}\n`);
  }
  process.exitCode = 1;
}
