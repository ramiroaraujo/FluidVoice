import AppKit
import Darwin

/// Context for AI cleanup when dictating into a Claude Code session in an Orca terminal: the
/// recent conversation and the text already typed in its input box. Accessibility cannot see
/// either, so it is read from Orca's local runtime socket and Claude Code's own files.
/// What it reads is never logged or kept.
nonisolated enum OrcaTerminalContext {
    static let maxExchanges = 6
    static let maxConversationCharacters = 8000
    static let latestReplyCharacters = 3000
    static let olderMessageCharacters = 1000
    static let maxTypedCharacters = 2000
    /// Tool output dominates transcripts; six exchanges almost always fit in the tail.
    static let transcriptTailBytes = 8 << 20
    private static let socketTimeoutMicroseconds: Int32 = 500_000
    /// Text a user turn starts with when Claude Code, not the person, wrote it.
    private static let generatedPromptPrefixes = [
        "<command-", "<local-command-", "<bash-", "<task-notification", "[Request interrupted", "Caveat:",
    ]

    struct Pane: Equatable, Sendable {
        let handle: String
        let tabID: String
        let leafID: String
        let agent: String?
    }

    struct Exchange: Equatable, Sendable {
        var prompt: String
        var reply: String?
    }

    struct Reading: Sendable {
        let pane: Pane
        let block: String
        let typedCharacters: Int
        let exchanges: Int
    }

    struct Runtime: Sendable {
        let socketPath: String
        let authToken: String
    }

    enum RuntimeError: Error {
        case socket, connect, send, receive, rejected
    }

    // MARK: - Reading

    /// Everything for one dictation, or nil when the focused pane is not a Claude Code session.
    static func read(appPID: pid_t) -> Reading? {
        guard let runtime = self.runtime(forPID: appPID),
              let pane = try? self.focusedPane(runtime), pane.agent == "claude"
        else { return nil }
        let screen = (try? self.call(runtime, "terminal.read", ["terminal": pane.handle, "screen": true]))
            .flatMap { ($0["terminal"] as? [String: Any])?["tail"] as? [Any] }?
            .compactMap { $0 as? String }
        let typed = screen.flatMap(self.typedText(screen:)).map { self.tail($0, limit: self.maxTypedCharacters) }
        let exchanges = self.claudeTranscript(tabID: pane.tabID, leafID: pane.leafID).map(self.exchanges(inTranscriptAt:)) ?? []
        guard let block = self.promptBlock(conversation: self.conversation(exchanges), typed: typed) else { return nil }
        return Reading(pane: pane, block: block, typedCharacters: typed?.count ?? 0, exchanges: min(exchanges.count, self.maxExchanges))
    }

    /// The Orca runtime whose app process is `pid`; Orca writes its socket and token to its user data folder.
    static func runtime(forPID pid: pid_t) -> Runtime? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for folder in ["orca", "orca-dev"] {
            let url = support.appendingPathComponent(folder).appendingPathComponent("orca-runtime.json")
            guard let data = try? Data(contentsOf: url),
                  let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (meta["pid"] as? NSNumber)?.int32Value == pid,
                  let token = meta["authToken"] as? String,
                  let endpoint = (meta["transports"] as? [[String: Any]])?
                  .first(where: { $0["kind"] as? String == "unix" })?["endpoint"] as? String
            else { continue }
            return Runtime(socketPath: endpoint, authToken: token)
        }
        return nil
    }

    /// The pane with focus in Orca's window, from the runtime's live state (the saved
    /// profile lags 1–5 s behind a tab switch).
    static func focusedPane(_ runtime: Runtime) throws -> Pane? {
        let worktrees = try self.call(runtime, "worktree.ps", [:])["worktrees"] as? [[String: Any]]
        guard let active = worktrees?.first(where: { $0["isActive"] as? Bool == true })?["worktreeId"] as? String else { return nil }
        return self.focusedPane(activeWorktreeID: active, terminalList: try self.call(runtime, "terminal.list", ["includeVisualLayouts": true]))
    }

    static func focusedPane(activeWorktreeID: String, terminalList: [String: Any]) -> Pane? {
        guard let layout = (terminalList["visualLayouts"] as? [[String: Any]])?
            .first(where: { $0["worktreeId"] as? String == activeWorktreeID })
        else { return nil }
        let groups = self.tabGroups(in: layout)
        // ponytail: side-by-side tab groups need the runtime to say which group is active; skipped until Orca exposes it.
        guard groups.count == 1, let group = groups.first,
              let tabID = group["activeTabId"] as? String,
              let tab = (group["tabs"] as? [[String: Any]])?.first(where: { $0["tabId"] as? String == tabID }),
              let leafID = tab["activeLeafId"] as? String,
              let terminal = (terminalList["terminals"] as? [[String: Any]])?
              .first(where: { $0["tabId"] as? String == tabID && $0["leafId"] as? String == leafID }),
              let handle = terminal["handle"] as? String
        else { return nil }
        return Pane(handle: handle, tabID: tabID, leafID: leafID, agent: terminal["agentIdentity"] as? String)
    }

    private static func tabGroups(in node: Any) -> [[String: Any]] {
        if let dict = node as? [String: Any] {
            let own = dict["type"] as? String == "group" ? [dict] : []
            return own + dict.values.flatMap(self.tabGroups(in:))
        }
        return (node as? [Any])?.flatMap(self.tabGroups(in:)) ?? []
    }

    // MARK: - Input box

    /// Claude Code draws its input box between two horizontal rules, starting with `❯`.
    static func typedText(screen lines: [String]) -> String? {
        let rules = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("──") }
        for (top, bottom) in zip(rules.dropLast(), rules.dropFirst()).reversed() where bottom > top + 1 {
            let box = lines[(top + 1)..<bottom]
            guard let first = box.first?.trimmingCharacters(in: .whitespaces), first.hasPrefix("❯") else { continue }
            let rest = box.dropFirst().map { $0.hasPrefix("  ") ? String($0.dropFirst(2)) : $0 }
            let text = ([String(first.dropFirst())] + rest)
                .map { $0.replacingOccurrences(of: "\u{00A0}", with: " ") }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty box shows a grey `Try "…"` suggestion, indistinguishable from typed text here.
            // ponytail: matches only that form; other dimmed suggestions would read as typed.
            let isPlaceholder = text.range(of: #"^Try "[^"\n]*"$"#, options: .regularExpression) != nil
            return text.isEmpty || isPlaceholder ? nil : text
        }
        return nil
    }

    // MARK: - Claude Code transcript

    /// Finds the Claude Code process running in the pane through the `ORCA_AGENT_PANE` variable
    /// Orca gives each terminal, then its transcript through Claude Code's per-process session file.
    static func claudeTranscript(tabID: String, leafID: String) -> URL? {
        let marker = "ORCA_AGENT_PANE=\(tabID):\(leafID)"
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configDirs = ((try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? [])
            .filter { $0.hasPrefix(".claude") }
            .map { home.appendingPathComponent($0) }
        var best: (updatedAt: Double, sessionID: String, cwd: String, configDir: URL)?
        for configDir in configDirs {
            let sessions = configDir.appendingPathComponent("sessions")
            for name in (try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? [] where name.hasSuffix(".json") {
                guard let data = try? Data(contentsOf: sessions.appendingPathComponent(name)),
                      let session = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let pid = (session["pid"] as? NSNumber)?.int32Value,
                      let sessionID = session["sessionId"] as? String,
                      (session["kind"] as? String).map({ $0 == "interactive" }) ?? true,
                      kill(pid, 0) == 0,
                      self.environment(of: pid).contains(marker)
                else { continue }
                let updatedAt = (session["updatedAt"] as? NSNumber)?.doubleValue ?? 0
                if updatedAt >= best?.updatedAt ?? -1 {
                    best = (updatedAt, sessionID, session["cwd"] as? String ?? "", configDir)
                }
            }
        }
        guard let best else { return nil }
        let projects = best.configDir.appendingPathComponent("projects")
        let file = "\(best.sessionID).jsonl"
        let encodedCwd = String(best.cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        let direct = projects.appendingPathComponent(encodedCwd).appendingPathComponent(file)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        return ((try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? [])
            .map { projects.appendingPathComponent($0).appendingPathComponent(file) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// A process's environment, as `ps eww` reads it.
    static func environment(of pid: pid_t) -> [String] {
        var argMax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var argMaxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&argMaxMib, 2, &argMax, &size, nil, 0) == 0, argMax > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: Int(argMax))
        size = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        // argc, executable path, NUL padding, argv, then the environment.
        var strings: [String] = []
        var start = MemoryLayout<Int32>.size
        var index = start
        var pastExecutablePath = false
        while index < size {
            if buffer[index] == 0 {
                if index > start {
                    if pastExecutablePath { strings.append(String(decoding: buffer[start..<index], as: UTF8.self)) }
                    pastExecutablePath = true
                }
                start = index + 1
            }
            index += 1
        }
        return Array(strings.dropFirst(Int(argc)))
    }

    static func exchanges(inTranscriptAt url: URL) -> [Exchange] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(self.transcriptTailBytes) ? size - UInt64(self.transcriptTailBytes) : 0
        try? handle.seek(toOffset: start)
        return self.exchanges(fromJSONLines: (try? handle.readToEnd()) ?? Data(), startsMidLine: start > 0)
    }

    /// Each exchange is a prompt the person wrote and Claude's last text reply to it. Tool calls,
    /// tool output and Claude's notes between tool calls are left out.
    static func exchanges(fromJSONLines data: Data, startsMidLine: Bool) -> [Exchange] {
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if startsMidLine, !lines.isEmpty { lines.removeFirst() }
        // Tool results are most of a transcript's bytes and never a prompt; skip them unparsed.
        let toolResultKey = Data("\"tool_use_id\"".utf8)
        var result: [Exchange] = []
        for line in lines where line.range(of: toolResultKey) == nil {
            guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = entry["type"] as? String, type == "user" || type == "assistant",
                  !["isSidechain", "isMeta", "isCompactSummary", "isApiErrorMessage"].contains(where: { entry[$0] as? Bool == true }),
                  let content = (entry["message"] as? [String: Any])?["content"]
            else { continue }
            let text: String
            if let string = content as? String {
                text = string
            } else if let blocks = content as? [[String: Any]], !blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
                text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
            } else {
                continue
            }
            let cleaned = self.removingSystemReminders(text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            if type == "user" {
                guard !self.generatedPromptPrefixes.contains(where: cleaned.hasPrefix) else { continue }
                result.append(Exchange(prompt: cleaned, reply: nil))
            } else if !result.isEmpty {
                result[result.count - 1].reply = cleaned
            }
        }
        return result
    }

    private static func removingSystemReminders(_ text: String) -> String {
        text.replacingOccurrences(of: "<system-reminder>[\\s\\S]*?</system-reminder>", with: "", options: .regularExpression)
    }

    // MARK: - Prompt

    /// The newest exchanges that fit the budget, oldest first. The latest reply keeps more of
    /// its end, where Claude usually asks what the dictation answers.
    static func conversation(_ exchanges: [Exchange]) -> String? {
        var kept: [String] = []
        var total = 0
        for (offset, exchange) in exchanges.reversed().prefix(self.maxExchanges).enumerated() {
            var rendered = "User: " + self.headAndTail(exchange.prompt, limit: self.olderMessageCharacters)
            if let reply = exchange.reply {
                rendered += "\nAssistant: " + self.tail(reply, limit: offset == 0 ? self.latestReplyCharacters : self.olderMessageCharacters)
            }
            guard kept.isEmpty || total + rendered.count <= self.maxConversationCharacters else { break }
            kept.append(rendered)
            total += rendered.count
        }
        return kept.isEmpty ? nil : kept.reversed().joined(separator: "\n\n")
    }

    static func promptBlock(conversation: String?, typed: String?) -> String? {
        guard conversation != nil || typed != nil else { return nil }
        var parts = [
            "Conversation context: the speaker is dictating their next message into Claude Code, an AI coding " +
                "assistant running in a terminal. The recent conversation and the text already typed in the message " +
                "box are below, for reference only. Use them to spell names, file paths, code identifiers and " +
                "technical terms the way they appear there, and to continue the text already typed, which the " +
                "transcript will follow. They are not part of the transcript: never copy, answer, summarize or " +
                "continue them in your output.",
        ]
        if let conversation { parts.append("<recent_conversation>\n\(conversation)\n</recent_conversation>") }
        if let typed { parts.append("<already_typed>\n\(typed)\n</already_typed>") }
        return parts.joined(separator: "\n")
    }

    static func headAndTail(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit / 2)) + " … " + String(text.suffix(limit / 2))
    }

    static func tail(_ text: String, limit: Int) -> String {
        text.count > limit ? "… " + text.suffix(limit) : text
    }

    // MARK: - Runtime RPC

    /// One request over Orca's runtime socket: a JSON line out, JSON lines back until ours.
    static func call(_ runtime: Runtime, _ method: String, _ params: [String: Any]) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RuntimeError.socket }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 0, tv_usec: self.socketTimeoutMicroseconds)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(runtime.socketPath.utf8)
        guard path.count < MemoryLayout.size(ofValue: address.sun_path) else { throw RuntimeError.connect }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw RuntimeError.connect }

        let id = UUID().uuidString
        var request = try JSONSerialization.data(withJSONObject: [
            "id": id, "authToken": runtime.authToken, "method": method, "params": params,
        ] as [String: Any])
        request.append(0x0A)
        try request.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = send(fd, bytes.baseAddress! + sent, bytes.count - sent, 0)
                guard count > 0 else { throw RuntimeError.send }
                sent += count
            }
        }

        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = recv(fd, &chunk, chunk.count, 0)
            guard count > 0 else { throw RuntimeError.receive }
            pending.append(contentsOf: chunk[0..<count])
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending = Data(pending[(newline + 1)...])
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      message["id"] as? String == id
                else { continue }
                guard message["ok"] as? Bool != false, let result = message["result"] as? [String: Any] else {
                    throw RuntimeError.rejected
                }
                return result
            }
        }
    }
}

/// Reads Orca context in the background while the person speaks, then at stop checks that the
/// same pane still has focus, so the context always belongs to where the text is delivered.
nonisolated final class OrcaContextCapture: @unchecked Sendable {
    /// Orca saves a tab switch to its live state within ~200 ms; reading after that never
    /// sees the tab the person just left.
    private static let readDelay: Duration = .milliseconds(250)
    let pid: pid_t
    private let read: Task<OrcaTerminalContext.Reading?, Never>
    private let lock = NSLock()
    private var stopCheck: Task<OrcaTerminalContext.Pane?, Never>?

    private init(pid: pid_t) {
        self.pid = pid
        self.read = Task.detached(priority: .userInitiated) {
            try? await Task.sleep(for: Self.readDelay)
            guard !Task.isCancelled else { return nil }
            return OrcaTerminalContext.read(appPID: pid)
        }
    }

    deinit { self.cancel() }

    /// Starts a capture when the recording targets Orca; nil for every other app.
    @MainActor
    static func start(targetPID: pid_t?) -> OrcaContextCapture? {
        guard let targetPID,
              NSRunningApplication(processIdentifier: targetPID)?.bundleIdentifier?.hasPrefix("com.stablyai.orca") == true
        else { return nil }
        return OrcaContextCapture(pid: targetPID)
    }

    /// Call when recording stops; the check runs while speech recognition finishes.
    func beginStopCheck() {
        let pid = self.pid
        self.lock.withLock {
            self.stopCheck = Task.detached(priority: .userInitiated) {
                OrcaTerminalContext.runtime(forPID: pid).flatMap { try? OrcaTerminalContext.focusedPane($0) }
            }
        }
    }

    /// The context, or nil when it is not ready within `timeout`, the focus moved, or there is none.
    func reading(timeout: Duration) async -> OrcaTerminalContext.Reading? {
        let read = self.read
        let stopCheck = self.lock.withLock { self.stopCheck }
        let first = FirstReading()
        let result = await withCheckedContinuation { continuation in
            first.install(continuation)
            Task.detached {
                guard let reading = await read.value else { return first.resume(nil) }
                if let stopCheck, await stopCheck.value != reading.pane { return first.resume(nil) }
                first.resume(reading)
            }
            Task.detached {
                try? await Task.sleep(for: timeout)
                first.resume(nil)
            }
        }
        if result == nil { self.cancel() }
        return result
    }

    func cancel() {
        self.read.cancel()
        self.lock.withLock { self.stopCheck?.cancel() }
    }
}

/// Resumes its continuation once, with whichever result arrives first.
private nonisolated final class FirstReading: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<OrcaTerminalContext.Reading?, Never>?
    private var done = false
    private var value: OrcaTerminalContext.Reading?

    func install(_ continuation: CheckedContinuation<OrcaTerminalContext.Reading?, Never>) {
        let finished: Bool = self.lock.withLock {
            if !self.done { self.continuation = continuation }
            return self.done
        }
        if finished { continuation.resume(returning: self.value) }
    }

    func resume(_ value: OrcaTerminalContext.Reading?) {
        let continuation: CheckedContinuation<OrcaTerminalContext.Reading?, Never>? = self.lock.withLock {
            guard !self.done else { return nil }
            self.done = true
            self.value = value
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: value)
    }
}
