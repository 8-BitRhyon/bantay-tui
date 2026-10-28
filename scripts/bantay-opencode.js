// bantay-opencode.js: openCode plugin that feeds agent events into Bantay's
// event pipeline AND answers approvals from the notch.
//
// Mechanism:
//   OUTBOUND (opencode -> Bantay): appends one canonical NDJSON line per event
//     to Bantay's events file (~/Library/Application Support/Bantay-TUI/
//     agent-events.jsonl), the same schema the app tails. Silent no-op if
//     Bantay isn't installed.
//   INBOUND (Bantay -> opencode): Bantay writes a decision file when you
//     Approve/Deny an opencode agent on the notch:
//     ~/Library/Application Support/Bantay-TUI/opencode-decisions/<project>.json
//     {"response": true|false, "choice": <1-based option>, "ts": <epoch>}.
//     This plugin polls it and answers the pending request, then removes the
//     file. This is what makes an "Approve" on the notch actually answer
//     opencode (not a phantom).
//
// Loader support:
//   openCode 2.x: default export { id, setup } (this file's primary shape).
//     setup uses ctx.event.subscribe(), ctx.permission.reply(), and
//     ctx.session.form when the host exposes it.
//   Kilo and older openCode: the named BantayOpenCode export keeps the
//     original V1 hook shape ({ event }) for hosts that call exported
//     functions directly.
//
// Event mapping (openCode 2.x event -> Bantay kind):
//   permission.asked          -> access_request (variance yes-no)
//   form.created              -> waiting (variance choices or multi)
//   session.execution.started -> progress (working, throttled)
//   session.execution.succeeded -> completed (done, throttled)
//   session.execution.failed  -> failed
//
// Form answers: a decision with "choice" replies to a pending single-choice
// or multi-select form with that one option. Multi-select Submit with
// several picks still happens in the terminal; the notch sends keystrokes
// for real panes, and this file route carries one explicit choice.
//
// Every event carries a stable per-project pane id ("opencode:<project>") so
// approvals are actionable on every Bantay surface and concurrent sessions
// don't collide on one identity key.
//
// Install: copy to ~/.config/opencode/plugins/bantay-opencode.js
// (Bantay Settings can do this automatically once installed.)

import { appendFile, mkdir, readFile, rm } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

const BANTAY_DIR = join(homedir(), "Library/Application Support/Bantay-TUI");
const EVENTS_FILE = join(BANTAY_DIR, "agent-events.jsonl");
const DECISIONS_DIR = join(BANTAY_DIR, "opencode-decisions");
const DECISION_GIVE_UP_MS = 15000;

function makeEmitter(paneId, workspaceId) {
  return async function emit(type, title, extra = {}) {
    const line = JSON.stringify({
      source: "opencode",
      type,
      title: title ?? null,
      message: extra.message ?? null,
      paneId,
      workspaceId: workspaceId ?? null,
      variance: extra.variance ?? null,
      choices: extra.choices ?? null,
    });
    try {
      await mkdir(BANTAY_DIR, { recursive: true });
      await appendFile(EVENTS_FILE, line + "\n", "utf8");
    } catch {
      // Bantay not installed: be a silent no-op.
    }
  };
}

function firstOptionField(form) {
  const fields = Array.isArray(form?.fields) ? form.fields : [];
  return fields.find((field) => Array.isArray(field?.options) && field.options.length > 0)
    ?? fields[0]
    ?? null;
}

// ---------------------------------------------------------------------------
// openCode 2.x: default export with setup().
// ---------------------------------------------------------------------------

async function setup(ctx) {
  const projectKey = ctx?.location?.project?.id ?? "default";
  const paneId = `opencode:${projectKey}`;
  const emit = makeEmitter(paneId, projectKey);
  const decisionFile = join(DECISIONS_DIR, `${projectKey}.json`);

  let disposed = false;
  let lastProgressAt = 0;
  let lastCompletedAt = 0;
  const pending = { permission: null, form: null };

  async function answerPermission(decision) {
    const target = pending.permission;
    if (!target) return false;
    try {
      await ctx.permission.reply({
        sessionID: target.sessionID,
        requestID: target.requestID,
        decision: decision.response ? "once" : "reject",
      });
      pending.permission = null;
      return true;
    } catch {
      return false;
    }
  }

  // The 2.x plugin session domain does not expose form replies, so fall
  // back to the server HTTP API discovered from the service registry the
  // opencode daemon writes on startup.
  async function formHttp(action, target, answer) {
    try {
      const raw = await readFile(
        join(homedir(), ".local/state/opencode/service.json"), "utf8");
      const service = JSON.parse(raw);
      if (!service?.url) return false;
      const headers = { "Content-Type": "application/json" };
      if (service.password) {
        headers.Authorization =
          "Basic " + Buffer.from(`opencode:${service.password}`).toString("base64");
      }
      const response = await fetch(
        `${service.url}/api/session/${target.sessionID}/form/${target.formID}/${action}`,
        {
          method: "POST",
          headers,
          body: JSON.stringify(action === "reply" ? { answer } : {}),
        });
      return response.ok;
    } catch {
      return false;
    }
  }

  async function answerForm(decision) {
    const target = pending.form;
    if (!target) return false;
    const formApi = ctx?.session?.form;
    if (decision.response === false) {
      try {
        if (typeof formApi?.cancel === "function") {
          await formApi.cancel({ sessionID: target.sessionID, formID: target.formID });
        } else if (!(await formHttp("cancel", target))) {
          return false;
        }
        pending.form = null;
        return true;
      } catch {
        return false;
      }
    }
    if (!Number.isInteger(decision.choice)) return false;
    const option = target.options[decision.choice - 1];
    if (!option) return false;
    const answer = {
      [target.fieldKey]: target.multiple ? [option.value] : option.value,
    };
    try {
      if (typeof formApi?.reply === "function") {
        await formApi.reply({
          sessionID: target.sessionID,
          formID: target.formID,
          answer,
        });
      } else if (!(await formHttp("reply", target, answer))) {
        return false;
      }
      pending.form = null;
      return true;
    } catch {
      return false;
    }
  }

  async function pollDecision() {
    let raw;
    try {
      raw = await readFile(decisionFile, "utf8");
    } catch {
      return; // No decision waiting.
    }
    let decision;
    try {
      decision = JSON.parse(raw);
    } catch {
      await rm(decisionFile, { force: true });
      return;
    }
    const answered = pending.permission
      ? await answerPermission(decision)
      : await answerForm(decision);
    if (answered) {
      await rm(decisionFile, { force: true });
      return;
    }
    // Nothing pending, or the host cannot answer this shape: drop stale
    // files after a grace period so one dead decision never loops forever.
    const age = Date.now() - Number(decision.ts ?? 0) * 1000;
    if ((!pending.permission && !pending.form) || age > DECISION_GIVE_UP_MS) {
      await rm(decisionFile, { force: true });
    }
  }

  const pollTimer = setInterval(() => {
    if (!disposed) void pollDecision();
  }, 400);
  pollTimer.unref?.();

  async function handle(event) {
    const data = event?.data ?? {};
    switch (event?.type) {
      case "permission.asked": {
        pending.permission = {
          sessionID: data.sessionID,
          requestID: data.id,
        };
        const resource = Array.isArray(data.resources) ? data.resources[0] : null;
        await emit("access_request", resource ?? data.action ?? "opencode needs approval", {
          message: data.action ? `opencode wants to run ${data.action}` : undefined,
          variance: "yes-no",
        });
        break;
      }
      case "permission.replied": {
        if (pending.permission?.requestID === data.requestID) pending.permission = null;
        break;
      }
      case "form.created": {
        const form = data.form ?? {};
        const field = firstOptionField(form);
        const options = Array.isArray(field?.options) ? field.options : [];
        const multiple = field?.type === "multiselect";
        pending.form = {
          sessionID: form.sessionID,
          formID: form.id,
          fieldKey: field?.key ?? "q0",
          multiple,
          options: options.map((option) => ({
            value: option?.value ?? option?.label ?? "",
            label: option?.label ?? option?.value ?? "",
          })),
        };
        await emit("waiting", form.title ?? field?.title ?? "opencode has a question", {
          message: field?.title ?? undefined,
          variance: options.length >= 2 ? (multiple ? "multi" : "choices") : undefined,
          choices: options.map((option) => option?.label ?? option?.value ?? ""),
        });
        break;
      }
      case "form.replied":
      case "form.cancelled": {
        if (pending.form?.formID === data.id) pending.form = null;
        break;
      }
      case "session.execution.started": {
        const now = Date.now();
        if (now - lastProgressAt < 500) break;
        lastProgressAt = now;
        await emit("progress", "working");
        break;
      }
      case "session.execution.succeeded": {
        const now = Date.now();
        if (now - lastCompletedAt < 20000) break;
        lastCompletedAt = now;
        await emit("completed", "opencode finished");
        break;
      }
      case "session.execution.failed": {
        await emit("failed", "opencode error");
        break;
      }
      default:
        break;
    }
  }

  void (async () => {
    try {
      for await (const event of ctx.event.subscribe()) {
        if (disposed) break;
        await handle(event);
      }
    } catch {
      // Event stream unavailable: stay silent rather than breaking the host.
    }
  })();

  return () => {
    disposed = true;
    clearInterval(pollTimer);
  };
}

export default { id: "bantay.opencode", setup };

// ---------------------------------------------------------------------------
// Legacy V1 shape for Kilo and older openCode hosts.
// ---------------------------------------------------------------------------

export const BantayOpenCode = async ({ project, client }) => {
  const projectKey = project?.id ?? "default";
  const paneId = `opencode:${projectKey}`;
  const emit = makeEmitter(paneId, project?.id);
  let lastIdleEmitAt = 0;
  return {
    event: async ({ event }) => {
      switch (event?.type) {
        case "permission.asked": {
          const props = event?.properties ?? event?.data ?? event;
          await emit("access_request", props?.tool ?? "opencode needs approval", {
            message: props?.tool ? `opencode wants to run ${props.tool}` : undefined,
            variance: "yes-no",
          });
          break;
        }
        case "session.idle": {
          const now = Date.now();
          if (now - lastIdleEmitAt < 20000) break;
          lastIdleEmitAt = now;
          await emit("completed", "opencode finished");
          break;
        }
        case "session.error": {
          await emit("failed", "opencode error");
          break;
        }
        default:
          break;
      }
    },
  };
};
