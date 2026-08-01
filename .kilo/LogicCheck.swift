import AppKit
import Foundation

@main
struct LogicCheckMain {
    static func main() {

var failures = 0

func check(_ condition: Bool, _ name: String) {
    if condition {
        print("PASS \(name)")
    } else {
        failures += 1
        print("FAIL \(name)")
    }
}

func agent(_ name: String, _ status: String, pane: String) -> HerdrAgentInfo {
    HerdrAgentInfo(
        agent: name,
        agentStatus: status,
        paneId: pane,
        workspaceId: String(pane.split(separator: ":").first ?? ""),
        terminalTitle: "\(name) | \(status)")
}

func expectKinds(_ events: [AgentEvent], _ kinds: [AgentEventKind], _ name: String) {
    check(events.map(\.kind) == kinds, "\(name): \(events.map(\.kind)) != \(kinds)")
}

// MARK: - capture update() logic

var seen: [String: AgentEventKind] = [:]
let first = AgentEventManager.update(
    from: [agent("kilo", "working", pane: "w3:p3")],
    lastSeenKinds: &seen,
    current: nil)
expectKinds(first.events, [.progress], "first poll emits working")
check(first.events.first?.playSound == true, "first poll plays sound")
check(first.events.first?.persistent == true, "working is persistent")
check(first.roster.map(\.source) == ["kilo"], "roster has kilo")

var seen2: [String: AgentEventKind] = [:]
let firstCall = AgentEventManager.update(
    from: [agent("kilo", "working", pane: "w3:p3")],
    lastSeenKinds: &seen2,
    current: nil)
let same = AgentEventManager.update(
    from: [agent("kilo", "working", pane: "w3:p3")],
    lastSeenKinds: &seen2,
    current: firstCall.events.first)
check(same.events.isEmpty, "same state does not re-emit")

var seen3: [String: AgentEventKind] = [:]
_ = AgentEventManager.update(
    from: [agent("kilo", "working", pane: "w3:p3")],
    lastSeenKinds: &seen3,
    current: nil)
let blocked = AgentEventManager.update(
    from: [agent("kilo", "blocked", pane: "w3:p3")],
    lastSeenKinds: &seen3,
    current: nil)
expectKinds(blocked.events, [.accessRequest], "working -> blocked emits accessRequest")

var seen4: [String: AgentEventKind] = [:]
let idle = AgentEventManager.update(
    from: [agent("kilo", "idle", pane: "w3:p3")],
    lastSeenKinds: &seen4,
    current: nil)
check(idle.events.isEmpty, "idle emits no event")
check(idle.roster.map(\.kind) == [.idle], "idle is in roster")

var seen5: [String: AgentEventKind] = [:]
let unknown = AgentEventManager.update(
    from: [agent("kilo", "unknown", pane: "w3:p3")],
    lastSeenKinds: &seen5,
    current: nil)
check(unknown.events.isEmpty && unknown.roster.isEmpty, "unknown excluded")

var seen6: [String: AgentEventKind] = [:]
let done = AgentEventManager.update(
    from: [agent("kilo", "done", pane: "w3:p3")],
    lastSeenKinds: &seen6,
    current: nil)
check(done.events.first?.kind == .completed, "done maps to completed")
check(done.events.first?.persistent == false, "done is not persistent")

var seen7: [String: AgentEventKind] = [:]
let sorted = AgentEventManager.update(
    from: [
        agent("kilo", "working", pane: "w3:p3"),
        agent("freebuff", "blocked", pane: "w3:p4"),
        agent("kilo2", "done", pane: "w3:p5"),
    ],
    lastSeenKinds: &seen7,
    current: nil)
check(sorted.roster.map(\.kind) == [.accessRequest, .completed, .progress], "roster sorted by severity")

var seen8: [String: AgentEventKind] = [:]
let shown = AgentEvent(
    source: "kilo",
    kind: .progress,
    title: nil,
    message: nil,
    paneId: "w3:p3",
    workspaceId: "w3",
    playSound: true,
    persistent: true)
let empty = AgentEventManager.update(from: [], lastSeenKinds: &seen8, current: shown)
expectKinds(empty.events, [.clear], "empty agents clears persistent event")
check(empty.roster.isEmpty, "empty agents clears roster")

var seen9: [String: AgentEventKind] = [:]
let pair = AgentEventManager.update(
    from: [
        agent("kilo", "blocked", pane: "w3:p3"),
        agent("freebuff", "working", pane: "w3:p4"),
    ],
    lastSeenKinds: &seen9,
    current: nil)
expectKinds(pair.events, [.progress, .accessRequest], "two agents emit both")
let fallback = AgentEventManager.update(
    from: [agent("freebuff", "working", pane: "w3:p4")],
    lastSeenKinds: &seen9,
    current: pair.events.last!)
expectKinds(fallback.events, [.clear, .progress], "vanish clears shown, falls back silently")
check(fallback.events.last?.source == "freebuff" && fallback.events.last?.playSound == false, "fallback is silent freebuff")

var seen10: [String: AgentEventKind] = [:]
_ = AgentEventManager.update(
    from: [agent("kilo", "working", pane: "w3:p3")],
    lastSeenKinds: &seen10,
    current: nil)
let reshown = AgentEventManager.update(
    from: [agent("kilo", "working", pane: "w3:p3")],
    lastSeenKinds: &seen10,
    current: nil)
expectKinds(reshown.events, [.progress], "same state reshows when current nil")
check(reshown.events.first?.playSound == false, "reshow is silent")

// MARK: - showEvent persistence (the blink bug)

let tmp = NSTemporaryDirectory() + "bantay-check-events.jsonl"
try? FileManager.default.removeItem(atPath: tmp)
FileManager.default.createFile(atPath: tmp, contents: nil)

let manager = AgentEventManager(eventsFileURL: URL(fileURLWithPath: tmp), capture: false)
func appendLine(_ json: String) {
    let handle = try! FileHandle(forWritingTo: URL(fileURLWithPath: tmp))
    try! handle.seekToEnd()
    try! handle.write(contentsOf: Data((json + "\n").utf8))
    try! handle.close()
}
func fileEvent(_ type: String) -> String {
    "{\"source\":\"herdr\",\"type\":\"\(type)\",\"title\":\"working\",\"message\":null,\"paneId\":\"w3:p3\",\"workspaceId\":\"w3\"}"
}

appendLine(fileEvent("progress"))
manager.poll()
check(manager.currentEvent?.kind == .progress, "file event shows")
let deadline = Date().addingTimeInterval(4.0)
while Date() < deadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
}
check(manager.currentEvent == nil, "transient file event auto-clears after TTL")

appendLine(fileEvent("progress"))
manager.poll()
check(manager.currentEvent?.kind == .progress, "second file event shows")
manager.stop()

manager.start()
appendLine(fileEvent("clear"))
manager.poll()
check(manager.currentEvent == nil, "clear dismisses")

manager.stop()
try? FileManager.default.removeItem(atPath: tmp)

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)

    }
}
