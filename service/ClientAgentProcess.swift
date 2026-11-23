import Darwin
import Foundation

/// A process as the kernel identifies it. PIDs are reused after a process
/// exits, so the start time tells two holders of one PID apart.
struct AcuaProcessIdentity: Equatable, Sendable {
    let pid: pid_t
    let parentPID: pid_t
    let startSeconds: Int
    let startMicroseconds: Int
}

enum AcuaProcessTable {
    /// nil when no such process exists (or it exited meanwhile).
    static func identity(of pid: pid_t) -> AcuaProcessIdentity? {
        var information = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]

        guard sysctl(&name, u_int(name.count), &information, &size, nil, 0) == 0 else {
            return nil
        }

        // A PID that does not exist still succeeds, with nothing written.
        guard size > 0, information.kp_proc.p_pid == pid else {
            return nil
        }

        let start = information.kp_proc.p_un.__p_starttime
        return AcuaProcessIdentity(pid: pid, parentPID: information.kp_eproc.e_ppid,
                                   startSeconds: Int(start.tv_sec), startMicroseconds: Int(start.tv_usec))
    }
}

/// The session of an agent that names none: the agent process itself.
///
/// Claude Code and Cursor send no session in `_meta`, while their stop hooks
/// know only the agent's own conversation ID, which the MCP helper never
/// sees. What both sides do share is the agent process: it starts the helper
/// over stdio as its child, and it runs the hook as its child, or as its
/// grandchild through `sh -c`. So the helper names its session after its
/// parent, and the hook ends the sessions named after its two nearest
/// ancestors. Every session inside one agent process therefore ends together.
enum AcuaAgentProcessSession {
    static let prefix = "acua-agent-"
    /// A process whose parent is launchd was not started by an agent.
    static let launchdPID: pid_t = 1
    /// The hook command (`AexComputerUseClient turn-ended --agent-process`)
    /// is the agent's child, or its grandchild when the agent's shell does
    /// not exec it. Going further up would reach the terminal or app that
    /// also hosts other agents.
    static let hookAncestorDepth = 2

    static func sessionID(_ agent: AcuaProcessIdentity) -> String {
        "\(prefix)\(agent.pid)-\(agent.startSeconds)." + String(format: "%06d", agent.startMicroseconds)
    }

    /// The session of the agent that started the MCP helper `helperPID`.
    static func helperSessionID(helperPID: pid_t, lookup: (pid_t) -> AcuaProcessIdentity?) -> String? {
        guard let helper = lookup(helperPID), helper.parentPID > launchdPID else {
            return nil
        }

        guard let agent = lookup(helper.parentPID) else {
            return nil
        }

        return sessionID(agent)
    }

    /// The sessions a stop hook running as `hookPID` may belong to, nearest
    /// ancestor first. Ending a session nobody opened is a no-op.
    static func hookSessionIDs(hookPID: pid_t, lookup: (pid_t) -> AcuaProcessIdentity?) -> [String] {
        var sessions: [String] = []
        var current = lookup(hookPID)

        for _ in 0..<hookAncestorDepth {
            guard let process = current, process.parentPID > launchdPID else {
                break
            }

            guard let parent = lookup(process.parentPID) else {
                break
            }

            sessions.append(sessionID(parent))
            current = parent
        }

        return sessions
    }
}

/// `turn-ended --agent-process`, the command Claude Code and Cursor stop hooks
/// run. It always exits successfully: a failed hook would show the user an
/// error for something they cannot fix, and a stop simply stays in place.
enum AcuaAgentTurnEnded {
    /// Returns one line for standard error. Standard output stays empty,
    /// because Cursor reads a stop hook's output as JSON.
    @MainActor static func run<Service>(
        sessionIDs: [String],
        findRunningService: () async throws -> Service?,
        send: (Service, AgentTurnEndedRequest) async throws -> Void
    ) async -> String {
        guard !sessionIDs.isEmpty else {
            return "Nothing to end: no agent process started this command."
        }

        let names = sessionIDs.joined(separator: ", ")

        // Like the Codex notify, ending a turn never launches the service:
        // a service that is not running holds no stop to release.
        guard let service = try? await findRunningService() else {
            return "Computer Use is not running, so nothing was stopped for \(names)."
        }

        var failures: [String] = []

        for session in sessionIDs {
            do {
                try await send(service, AgentTurnEndedRequest(threadID: session, turnID: nil))
            } catch {
                failures.append("could not end \(session): \(String(describing: error as NSError))")
            }
        }

        guard failures.isEmpty else {
            return "Ended the agent sessions except where noted (\(names)); " + failures.joined(separator: "; ") + "."
        }

        return "Ended the agent sessions \(names)."
    }
}
