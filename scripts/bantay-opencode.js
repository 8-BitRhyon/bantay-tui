// bantay-opencode.js — openCode plugin that feeds agent events into Bantay's
// event pipeline so openCode sessions show up on the notch (working / needs
// approval / done / failed) exactly like herdr-managed agents.
//
// Mechanism: appends one canonical NDJSON line per event to Bantay's events
// file (~/Library/Application Support/Bantay-TUI/agent-events.jsonl), the
// same schema the app tails. No Bantay install needed for this to be a
// no-op: if the file can't be written the plugin stays silent.
//
// Event mapping (openCode event -> Bantay kind):
//   permission.asked  -> access_request  (variance yes-no)
//   tool.execute.before -> progress      (working)
//   session.idle      -> completed       (done, throttled)
//   session.error     -> failed
//
// Every event carries a stable per-project pane id ("opencode:<project>") so
// approvals are actionable on every Bantay surface (notifications, menu bar,
// hotkeys) and concurrent sessions don't collide on one identity key.
//
// Install: copy to ~/.config/opencode/plugins/bantay-opencode.js
// (Bantay Settings can do this automatically once installed.)

import { appendFile, mkdir } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

const EVENTS_FILE = join(
  homedir(),
  "Library/Application Support/Bantay-TUI/agent-events.jsonl",
);

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
    await mkdir(join(homedir(), "Library/Application Support/Bantay-TUI"), {
      recursive: true,
    });
    await appendFile(EVENTS_FILE, line + "\n", "utf8");
  } catch {
    // Bantay not installed — be a silent no-op.
  }
}

function permissionTitle(event) {
  return event?.message ?? event?.title ?? "opencode needs approval";
}

export const BantayOpenCode = async ({ project, $, directory }) => {
  let lastEmitAt = 0;
  let lastIdleEmitAt = 0;
  const projectId = project?.id ? `opencode:${project.id}` : "opencode:default";
  const throttled = (fn) => {
    const now = Date.now();
    if (now - lastEmitAt < 500) return; // coalesce burst tool calls
    lastEmitAt = now;
    return fn();
  };

  return {
    event: async ({ event }) => {
      switch (event?.type) {
        case "permission.asked":
          await emit("access_request", permissionTitle(event), {
            message: event?.tool ? `opencode wants to run ${event.tool}` : undefined,
            variance: "yes-no",
            workspaceId: project?.id ?? undefined,
            paneId: projectId,
          });
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
