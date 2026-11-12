import ApelinCore
import ApelinProtocol
import Foundation

// The idle clock and the work report (Apelind/Session/TaskRegistry.swift's
// `holdsWork`, `busyCount` and `retireIdle`, WorkerSupervisor.sweep, and
// ApelinProtocol's WorkReport.isIdle): the background service exits a quarter
// of an hour after its last real work, so what counts as work is what keeps it
// up. A conversation left open between turns is an unfinished task with a live
// worker, and is not work; the turn inside it counts from its `messageStarted`
// to its `finished` — the two events the agent session writes, `messageStarted`
// durable and relayed before any answer. A worker retired after a long idle
// ends its tasks as ones that finished, since nothing failed and nothing serves
// them any more; a worker whose process went away still fails them.

func idleWorkChecks(scratch: URL) async {
    let directory = scratch.appendingPathComponent("idle-tasks")
    let registry = TaskRegistry(directory: directory)
    await registry.load()

    // MARK: A conversation between turns is not work

    let chat = "session-idle-1"
    let conversation = await registry.create(kind: .agent, owner: .agent, ownerKey: chat)
    var busy = await registry.busyCount
    var active = await registry.activeCount
    var holds = await registry.hasWorkInFlight(owner: .agent, key: chat)
    check(busy == 0, "an open conversation with nothing running is not work in flight")
    check(active == 1, "but it is an active task, for the report's other figure")
    check(holds == false, "and its worker holds nothing up")
    check(WorkReport(activeTasks: 1, busyTasks: 0, workers: 1, busyWorkers: 0, toolHosts: 0).isIdle, "so the report is idle and the service may exit")
    check(WorkReport(activeTasks: 0, workers: 0, toolHosts: 1).isIdle == false, "an open tool extension still holds it up")

    // MARK: A turn counts from its first message to the run's end

    _ = await registry.append(conversation.taskID, kind: "prompt", payload: .object(["text": .string("Build it")]))
    busy = await registry.busyCount
    check(busy == 0, "a message written down is not a turn yet")
    _ = await registry.append(conversation.taskID, kind: TaskRegistry.turnStartedKind, payload: nil)
    holds = await registry.hasWorkInFlight(owner: .agent, key: chat)
    busy = await registry.busyCount
    check(holds, "the run's first assistant message starts the turn")
    check(busy == 1, "which is work in flight while the task stays active")
    check(WorkReport(activeTasks: 1, busyTasks: 1, workers: 1, busyWorkers: 1, toolHosts: 0).isIdle == false, "and holds the service up")
    _ = await registry.append(conversation.taskID, kind: TaskRegistry.turnFinishedKind, payload: nil)
    holds = await registry.hasWorkInFlight(owner: .agent, key: chat)
    busy = await registry.busyCount
    active = await registry.activeCount
    check(holds == false && busy == 0, "the run's end leaves the conversation idle again")
    check(active == 1, "with its task still open for the app")

    // A build is work from the moment it is made: it has no turns.
    let build = await registry.create(kind: .build, owner: .build, ownerKey: "project-1")
    holds = await registry.hasWorkInFlight(owner: .build, key: "project-1")
    busy = await registry.busyCount
    check(holds, "a build is work in flight with no turn of its own")
    check(busy == 1, "and is counted")
    let byKind = await registry.activeByKind
    check(byKind["build"] == 1 && byKind["agent"] == 1, "the report's per-kind figures count the same tasks")

    // MARK: A worker retired after a long idle ends its task as one that finished

    let idle = await registry.create(kind: .agent, owner: .agent, ownerKey: "session-idle-2")
    await registry.retireIdle(owner: .agent, key: "session-idle-2")
    let retired = await registry.record(idle.taskID)
    busy = await registry.busyCount
    check(retired?.state == .succeeded, "a worker retired after a long idle ends its task as one that finished")
    check(busy == 1, "and only the build's work is left in flight")
    let untouched = await registry.record(conversation.taskID)
    check(untouched?.state == .running, "another conversation's task is left alone")

    // Mid-turn, too, and the turn goes with it.
    let cut = await registry.create(kind: .agent, owner: .agent, ownerKey: "session-idle-3")
    _ = await registry.append(cut.taskID, kind: TaskRegistry.turnStartedKind, payload: nil)
    busy = await registry.busyCount
    check(busy == 2, "a turn in a second conversation is counted as well")
    await registry.retireIdle(owner: .agent, key: "session-idle-3")
    let cutRecord = await registry.record(cut.taskID)
    busy = await registry.busyCount
    check(cutRecord?.state == .succeeded, "a worker retired in the middle of a turn ends the task")
    check(busy == 1, "and its turn is no longer work")

    // A process that went away is not a retirement: its task failed.
    let dead = await registry.create(kind: .agent, owner: .agent, ownerKey: "session-idle-4")
    await registry.ownerExited(role: .agent, key: "session-idle-4")
    let deadRecord = await registry.record(dead.taskID)
    check(deadRecord?.state == .failed, "a worker whose process went away fails its task instead")

    await registry.finish(build.taskID, .succeeded)
    busy = await registry.busyCount
    check(busy == 0, "no work is left after everything ended")

    // MARK: A turn is not read back from the log when the host starts over

    let cutShort = await registry.create(kind: .agent, owner: .agent, ownerKey: "session-idle-5")
    _ = await registry.append(cutShort.taskID, kind: TaskRegistry.turnStartedKind, payload: nil)
    busy = await registry.busyCount
    check(busy == 1, "a turn is work in flight while the host is up")
    let restarted = TaskRegistry(directory: directory)
    let unfinished = await restarted.load()
    busy = await restarted.busyCount
    check(busy == 0, "a host that starts over has nothing in flight")
    check(unfinished.contains { $0.id == cutShort.taskID }, "and the task is handed back to be resumed or ended")
    await restarted.interrupt(cutShort.taskID, message: "The background service restarted.")
    busy = await restarted.busyCount
    let ended = await restarted.record(cutShort.taskID)
    check(busy == 0, "an interrupted task is not work either")
    check(ended?.state == .interrupted, "and it is not resumed over")
}
