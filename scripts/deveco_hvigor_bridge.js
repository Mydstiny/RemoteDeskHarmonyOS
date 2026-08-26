#!/usr/bin/env node

'use strict';

const path = require('path');
const { spawnSync } = require('child_process');

const projectRoot = path.resolve(__dirname, '..');
const shellCommand = [
  'source "$1/scripts/macos_env.sh"',
  'exec "$1/scripts/macos_hvigorw.sh" "${@:2}"'
].join(' && ');
const result = spawnSync('/bin/bash', [
  '-c',
  shellCommand,
  'remotedesk-deveco-hvigor',
  projectRoot,
  ...process.argv.slice(2)
], {
  cwd: projectRoot,
  env: process.env,
  stdio: 'inherit'
});

if (result.error) {
  console.error(`RemoteDesk DevEco Hvigor bridge: ${result.error.message}`);
  process.exit(1);
}

if (result.signal) {
  console.error(`RemoteDesk DevEco Hvigor bridge: build terminated by ${result.signal}`);
  process.exit(128);
}

process.exit(result.status ?? 1);
