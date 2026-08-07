// bantay-opencode.js — openCode plugin that feeds agent events into Bantay's
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
//     {"response": true|false, "ts": <epoch>}. This plugin polls it and calls
//     the opencode server's permission endpoint to answer the pending
//     permission.asked, then removes the file. This is what makes an
//     "Approve" on the notch actually answer opencode (not a phantom).
//
// Event mapping (opencode event -> Bantay kind):
//   permission.asked   -> access_request  (variance yes-no)
//   tool.execute.before -> progress        (working)
//   session.idle       -> completed        (done, throttled)
//   session.error      -> failed
//
// Every event carries a stable per-project pane id ("opencode:<project>") so
// approvals are actionable on every Bantay surface and concurrent sessions
// don't collide on one identity key.
//
// Install: copy to ~/.config/opencode/plugins/bantay-opencode.js
// (Bantay Settings can do this automatically once installed.)

import { appendFile, mkdir, readFile, rm, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

const BANTAY_DIR = join(homedir(), "Library/Application Support/Bantay-TUI");
const EVENTS_FILE = join(BANTAY_DIR, "agent-events.jsonl");
const DECISIONS_DIR = join(BANTAY_DIR, "opencode-decisions");

async function emit(type, title, extra = {}) {
  const paneId = extra.paneId ?? "opencode:default";
  const line = JSON.stringify({
    source: "opencode",
    type,
    title,
    message: extra.message ?? null,
    paneId,
    workspaceId: extra.workspaceId ?? null,
    variance: extra.variance ?? null,
    choices: extra.choices ?? null,
  });
  try {
    await mkdir(BANTAY_DIR, { recursive: true });
    await appendFile(EVENTS_FILE, line + "\n", "utf8");
  } catch {
    // Bantay not installed — be a silent no-op.
  }
}

function permissionTitle(event) {
  return event?.message ?? event?.title ?? "opencode needs approval";
}

// The current pending permission (sessionID + permissionID + permission
// "type") for each project, so an inbound decision from Bantay can answer it.
const pendingPermissionByProject = new Map();

// Whether we are already polling for a project (one poll loop per project).
const pollingByProject = new Set();

export const BantayOpenCode = async ({ project, client, $, directory }) => {
  let lastEmitAt = 0;
  let lastIdleEmitAt = 0;
  const projectKey = project?.id ?? "default";
  const projectId = `opencode:${projectKey}`;
  const decisionFile = join(DECISIONS_DIR, `${projectKey}.json`);
  const throttled = (fn) => {
    const now = Date.now();
    if (now - lastEmitAt < 500) return; // coalesce burst tool calls
    lastEmitAt = now;
    return fn();
  };

  // Answer a pending permission via the opencode SDK client.
  async function answerPending(response) {
    const pending = pendingPermissionByProject.get(projectKey);
    if (!pending) return false;
    try {
      await client.session.postSessionByIdPermissionsByPermissionId({
        path: { id: pending.sessionID, permissionID: pending.permissionID },
        body: { response },
      });
      pendingPermissionByProject.delete(projectKey);
      return true;
    } catch {
      // Keep the pending entry; the poll loop will retry on the next file.
      return false;
    }
  }

  // Poll Bantay's decision file for this project; answer + remove on arrival.
  async function pollDecisions() {
    if (pollingByProject.has(projectKey)) return;
    pollingByProject.add(projectKey);
    while (true) {
      try {
        const raw = await readFile(decisionFile, "utf8");
        const decision = JSON.parse(raw);
        const answered = await answerPending(Boolean(decision.response));
        if (answered) {
          await rm(decisionFile, { force: true });
        }
      } catch {
        // No file yet / malformed — keep polling.
      }
      await new Promise((r) => setTimeout(r, 400));
    }
  }

  // Start polling on the first permission.asked so we're ready for decisions.
  pollDecisions();

  return {
    event: async ({ event }) => {
      switch (event?.type) {
        case "permission.asked": {
          const props = event?.properties ?? event?.data ?? event;
          const sessionID =
            props?.sessionID ?? props?.sessionId ?? props?.id ?? "";
          const permissionID =
            props?.permissionID ?? props?.permissionId ?? "";
          if (sessionID && permissionID) {
            pendingPermissionByProject.set(projectKey, {
              sessionID,
              permissionID,
              tool: props?.tool ?? "",
            });
          }
          await emit("access_request", permissionTitle(event), {
            message: props?.tool ? `opencode wants to run ${props.tool}` : undefined,
            variance: "yes-no",
            workspaceId: project?.id ?? undefined,
            paneId: projectId,
          });
          break;
        }
        case "permission.replied":
          pendingPermissionByProject.delete(projectKey);
          break;
        case "tool.execute.before":
          await throttled(() =>
            emit(
              "progress",
              event?.tool ? `running ${event.tool}` : "working",
              { workspaceId: project?.id ?? undefined, paneId: projectId },
            ),
          );
          break;
        case "session.idle":
          // openCode fires idle after every turn; only surface a completion
          // when the agent actually reached an end (not mid-approval), and
          // throttle to one per 20s so turns don't churn sounds/recents.
          const now = Date.now();
          if (now - lastIdleEmitAt < 20000) break;
          lastIdleEmitAt = now;
          await emit("completed", "opencode finished", {
            message: event?.error ?? undefined,
            workspaceId: project?.id ?? undefined,
            paneId: projectId,
          });
          break;
        case "session.error":
          await emit("failed", "opencode error", {
            message: event?.error ?? undefined,
            workspaceId: project?.id ?? undefined,
            paneId: projectId,
          });
          break;
        default:
          break;
      }
    },
  };
};
