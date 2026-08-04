#!/usr/bin/env node
'use strict';

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const DATA_DIR = path.join(os.homedir(), 'Library', 'Application Support', 'Bantay-TUI');
const EVENTS_FILE = path.join(DATA_DIR, 'agent-events.jsonl');

const STATUS_MAP = {
  blocked: 'access_request',
  done: 'completed',
  working: 'progress',
  running: 'started',
  idle: 'waiting',
  failed: 'failed',
  cancelled: 'cancelled',
  clear: 'clear',
};

const eventJson = process.env.HERDR_PLUGIN_EVENT_JSON;
if (!eventJson) {
  process.exit(0);
}

let event;
try {
  event = JSON.parse(eventJson);
} catch {
  process.exit(0);
}

const data = event.data;
if (!data || !data.agent_status) {
  process.exit(0);
}

const status = (data.agent_status || '').trim().toLowerCase();
const mapped = STATUS_MAP[status];
if (!mapped) {
  process.exit(0);
}

const stateLabels = data.state_labels && typeof data.state_labels === 'object'
  ? data.state_labels
  : null;

// Prefer the label for the current status (raw or mapped key); fall back to
// the first label only when the status has no entry.
const message =
  (stateLabels && (stateLabels[status] || stateLabels[mapped])) ||
  (stateLabels && Object.values(stateLabels)[0]) ||
  data.custom_status ||
  null;

const payload = {
  source: data.display_agent || data.agent || 'herdr',
  type: mapped,
  title: data.title || null,
  message,
  paneId: data.pane_id || null,
  workspaceId: data.workspace_id || null,
  variance: data.variance || null,
  choices: data.choices || data.options || null,
};

try {
  fs.mkdirSync(DATA_DIR, { recursive: true });
  fs.appendFileSync(EVENTS_FILE, JSON.stringify(payload) + '\n', 'utf8');
} catch (err) {
  console.error('bantay-tui: failed to write event:', err.message);
  process.exit(1);
}
