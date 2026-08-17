// model-routing-alarm.js — DeepSeek Pro/Flash routing alarm plugin.
//
// Watches tool executions and raises a loud alarm when countable signals say
// the session should switch models (Flash <-> Pro). This plugin handles only
// MECHANICAL signals — things that can be counted by thresholding tool calls:
//
//   failing test runs          -> escalate to Pro
//   repeated edits to one file -> escalate to Pro (stuck loop)
//   mechanical green phase
//     while running on Pro     -> suggest downgrade to Flash
//
// Judgment signals (silent Indic-normalization corruption, cross-language
// contract drift, Bazel build-graph weirdness, "lost the thread") are NOT
// countable and are NOT handled here. They are handled by the routing contract
// in model-routing.md, loaded via opencode.json `instructions`; the agent
// emits a loud `⚠️ SWITCH-TO-*:` marker when one fires.
//
// An alarm is a macOS notification (osascript) plus a queued session banner
// (client.session.prompt, noReply -> visible but does not preempt the agent).
// The injected banner tells the agent to acknowledge, not act, so it cannot
// feed a second alarm. A per-session cooldown (default 10 min) prevents spam.
//
// Safety contract: this plugin must NEVER throw. Every handler is wrapped so a
// failure degrades to a log line instead of silently killing the plugin.
//
// Environment (all optional):
//   MODEL_ROUTING_FAIL_THRESHOLD    consecutive failing test runs -> Pro     (2)
//   MODEL_ROUTING_LOOP_THRESHOLD    consecutive edits to one file -> Pro     (4)
//   MODEL_ROUTING_GREEN_THRESHOLD   consecutive green passes on Pro -> Flash (5)
//   MODEL_ROUTING_COOLDOWN_MIN      minutes between alarms                   (10)
//   MODEL_ROUTING_NOTIFY            "0" disables the macOS notification      (1)
//   MODEL_ROUTING_DEBUG             "1" enables stderr logging
//
// Install: symlink into ~/.config/opencode/plugin/ (auto-discovered).

import { execFile } from "node:child_process";
import { appendFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const LOG_FILE = join(tmpdir(), "model-routing-alarm.log");
const DEBUG = process.env.MODEL_ROUTING_DEBUG === "1";

const DEFAULTS = {
  FAIL_THRESHOLD: 2,
  LOOP_THRESHOLD: 4,
  GREEN_THRESHOLD: 5,
  COOLDOWN_MIN: 10,
};

function envInt(name, fallback) {
  const raw = process.env[name];
  const parsed = raw ? parseInt(raw, 10) : NaN;
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

function log(message) {
  const line = `[${new Date().toISOString()}] ${message}\n`;
  if (DEBUG) console.error("[model-routing]", line.trim());
  try {
    appendFileSync(LOG_FILE, line);
  } catch {
    // Ignore file write errors.
  }
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

// sessionID -> { model, failStreak, loopFile, loopCount, greenStreak, lastAlarm }
const state = new Map();

function sessionState(sessionID) {
  let entry = state.get(sessionID);
  if (!entry) {
    entry = { model: null, failStreak: 0, loopFile: null, loopCount: 0, greenStreak: 0, lastAlarm: 0 };
    state.set(sessionID, entry);
  }
  return entry;
}

// ---------------------------------------------------------------------------
// Signal detection
// ---------------------------------------------------------------------------

const TEST_RUNNER_RE = [
  /(^|[;&|]\s*)pytest(\s|$)/,
  /(^|[;&|]\s*)python\d* -m pytest(\s|$)/,
  /(^|[;&|]\s*)bazel test(\s|$)/,
  /(^|[;&|]\s*)vitest(\s|$)/,
  /(^|[;&|]\s*)jest(\s|$)/,
  /(^|[;&|]\s*)npm (run )?test(\s|$)/,
  /(^|[;&|]\s*)yarn test(\s|$)/,
  /(^|[;&|]\s*)pnpm test(\s|$)/,
  /(^|[;&|]\s*)go test(\s|$)/,
  /(^|[;&|]\s*)mix test(\s|$)/,
  /(^|[;&|]\s*)mvn test(\s|$)/,
];

// The runner must be a leading command word or follow a separator (`&&`, `;`,
// `|`), NOT an argument to another command. This keeps "pip install pytest"
// from counting as a test run.
function isTestRunner(command) {
  const trimmed = command.trim();
  return TEST_RUNNER_RE.some((re) => re.test(trimmed));
}

const STRONG_FAILURE_RE = /FAILED|Traceback|AssertionError|non-zero exit|Exit code [1-9]\d*/i;

function isFailure(out, output) {
  if (STRONG_FAILURE_RE.test(out)) return true;
  const meta = (output && output.metadata) || {};
  const code = meta.exitCode ?? meta.code ?? meta.status;
  return code !== undefined && code !== null && String(code) !== "0";
}

function isProModel(modelID) {
  return typeof modelID === "string" && /pro/i.test(modelID);
}

// ---------------------------------------------------------------------------
// Alarm
// ---------------------------------------------------------------------------

let sdkClient = null;

function escapeAppleScript(value) {
  return String(value).replace(/[\\"]/g, "\\$&");
}

function notify(title, message) {
  if (process.env.MODEL_ROUTING_NOTIFY === "0") return;
  const script = `display notification "${escapeAppleScript(message)}" with title "${escapeAppleScript(title)}"`;
  execFile("osascript", ["-e", script], (err) => {
    if (err) log(`osascript notification failed: ${err.message}`);
  });
}

// Inject a visible banner into the session without preempting the agent
// (noReply: true). Falls back to the v2 SDK shape if the v1 call rejects.
function banner(sessionID, text) {
  if (!sdkClient || !sessionID) return;
  const tryV1 = sdkClient.session.prompt({
    path: { id: sessionID },
    body: { parts: [{ type: "text", text }], noReply: true },
  });
  tryV1.then(
    () => log(`banner injected into ${sessionID}`),
    () => {
      sdkClient.session
        .prompt({ path: { sessionID }, body: { prompt: { text }, delivery: "queue" } })
        .then(
          () => log(`banner injected into ${sessionID} (v2 shape)`),
          (err) => log(`banner injection failed: ${err && err.message}`),
        );
    },
  );
}

function maybeAlarm(sessionID, direction, reason) {
  const entry = sessionState(sessionID);
  const cooldownMs = envInt("MODEL_ROUTING_COOLDOWN_MIN", DEFAULTS.COOLDOWN_MIN) * 60 * 1000;
  if (Date.now() - entry.lastAlarm < cooldownMs) {
    log(`alarm suppressed (cooldown): switch-to-${direction} for ${reason}`);
    return;
  }
  entry.lastAlarm = Date.now();

  const title = direction === "PRO" ? "Escalate to Pro" : "Downgrade to Flash";
  const text =
    `⚠️ SWITCH-TO-${direction}: ${reason}. ` +
    `Consider switching this session's model (V4 Pro for hard reasoning, ` +
    `V4 Flash for routine work). Acknowledge and continue; do not act on this message.`;
  log(`ALARM switch-to-${direction}: ${reason} (session ${sessionID})`);
  notify(title, text);
  banner(sessionID, text);
}

// ---------------------------------------------------------------------------
// Event / tool handling
// ---------------------------------------------------------------------------

function trackModel(event) {
  if (!event || typeof event !== "object") return;
  const type = event.type || "";
  if (!/model\.?switched/i.test(type)) return;
  const props = event.properties || event.data || {};
  const sessionID = props.sessionID;
  const model = (props.model && props.model.id) || props.model || event.model;
  if (!sessionID || !model) return;
  sessionState(sessionID).model = String(model);
  log(`model for ${sessionID}: ${model}`);
}

function handleToolAfter(input, output) {
  const { tool, sessionID, args } = input;
  if (!sessionID || !args) return;
  const entry = sessionState(sessionID);

  if (tool === "bash") {
    const command = String(args.command || "");
    const out = String((output && output.output) || (output && output.title) || "");
    if (!isTestRunner(command)) return;

    if (isFailure(out, output)) {
      entry.failStreak += 1;
      entry.greenStreak = 0;
      const threshold = envInt("MODEL_ROUTING_FAIL_THRESHOLD", DEFAULTS.FAIL_THRESHOLD);
      if (entry.failStreak >= threshold) {
        const first = command.trim().split(/\s+/)[0];
        maybeAlarm(sessionID, "PRO", `${entry.failStreak} consecutive failing test runs (${first})`);
        entry.failStreak = 0;
      }
    } else {
      entry.failStreak = 0;
      if (isProModel(entry.model)) {
        entry.greenStreak += 1;
        const threshold = envInt("MODEL_ROUTING_GREEN_THRESHOLD", DEFAULTS.GREEN_THRESHOLD);
        if (entry.greenStreak >= threshold) {
          maybeAlarm(sessionID, "FLASH", `${entry.greenStreak} consecutive green passes while on Pro`);
          entry.greenStreak = 0;
        }
      }
    }
    return;
  }

  if (tool === "edit" || tool === "write") {
    const filePath = args.filePath || args.path || args.file;
    const fp = filePath ? String(filePath) : null;
    if (!fp) return;
    if (fp === entry.loopFile) {
      entry.loopCount += 1;
      const threshold = envInt("MODEL_ROUTING_LOOP_THRESHOLD", DEFAULTS.LOOP_THRESHOLD);
      if (entry.loopCount >= threshold) {
        maybeAlarm(sessionID, "PRO", `${entry.loopCount} consecutive edits to ${fp}`);
        entry.loopCount = 0;
      }
    } else {
      entry.loopFile = fp;
      entry.loopCount = 1;
    }
  }
}

// ---------------------------------------------------------------------------
// Plugin export
// ---------------------------------------------------------------------------

export const ModelRoutingAlarm = async ({ client }) => {
  sdkClient = client;
  log("model-routing alarm plugin loaded");
  return {
    event: (input) => {
      try {
        trackModel(input && input.event);
      } catch (err) {
        log(`event handler threw: ${err && err.stack ? err.stack : err}`);
      }
    },
    "tool.execute.after": async (input, output) => {
      try {
        handleToolAfter(input, output);
      } catch (err) {
        log(`tool.execute.after threw: ${err && err.stack ? err.stack : err}`);
      }
    },
  };
};
