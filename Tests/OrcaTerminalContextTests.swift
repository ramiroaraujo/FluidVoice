import Foundation

@main
enum OrcaTerminalContextTests {
    static func main() throws {
        self.inputBox()
        try self.transcript()
        self.budget()
        self.focusedPane()
        self.promptBlock()
        print("OrcaTerminalContextTests passed")
    }

    static func inputBox() {
        let rule = String(repeating: "─", count: 40)
        let screen = ["⏺ Done.", rule, "❯ fix the parser", "  and add a test", rule, "  Opus 5.5 │ FluidVoice │ main"]
        precondition(OrcaTerminalContext.typedText(screen: screen) == "fix the parser\nand add a test")
        precondition(OrcaTerminalContext.typedText(screen: ["older", rule, "❯ old", rule, "out", rule, "❯\u{00A0}new", rule]) == "new")
        precondition(OrcaTerminalContext.typedText(screen: [rule, "❯", rule]) == nil)
        precondition(OrcaTerminalContext.typedText(screen: [rule, "❯\u{00A0}Try \"fix typecheck errors\"", rule]) == nil)
        precondition(OrcaTerminalContext.typedText(screen: [rule, "❯ Try \"this\" and that", rule]) == "Try \"this\" and that")
        precondition(OrcaTerminalContext.typedText(screen: [rule, "Do you want to proceed?", rule]) == nil)
        precondition(OrcaTerminalContext.typedText(screen: ["no box here"]) == nil)
    }

    static func transcript() throws {
        func line(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        func user(_ content: Any, _ extra: [String: Any] = [:]) throws -> String {
            try line(["type": "user", "message": ["role": "user", "content": content]].merging(extra) { $1 })
        }
        func assistant(_ blocks: [[String: Any]]) throws -> String {
            try line(["type": "assistant", "message": ["role": "assistant", "content": blocks]])
        }
        let lines = try [
            "{\"partial\": \"line cut by the tail read",
            assistant([["type": "text", "text": "reply before any prompt in the tail"]]),
            user("first prompt"),
            assistant([["type": "text", "text": "Let me check."]]),
            assistant([["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "ls"]]]),
            user([["type": "tool_result", "tool_use_id": "t1", "content": "huge output"]]),
            assistant([["type": "thinking", "thinking": "hmm"], ["type": "text", "text": "Final answer one."]]),
            user([["type": "text", "text": "<system-reminder>injected</system-reminder>second prompt"]]),
            user("<command-name>/clear</command-name>"),
            user("skill body", ["isMeta": true]),
            user("subagent prompt", ["isSidechain": true]),
            assistant([["type": "text", "text": "Final answer two."]]),
            user("[Request interrupted by user]"),
            user("third prompt, still running"),
        ]
        let exchanges = OrcaTerminalContext.exchanges(fromJSONLines: Data(lines.joined(separator: "\n").utf8), startsMidLine: true)
        precondition(exchanges == [
            .init(prompt: "first prompt", reply: "Final answer one."),
            .init(prompt: "second prompt", reply: "Final answer two."),
            .init(prompt: "third prompt, still running", reply: nil),
        ], "\(exchanges)")
    }

    static func budget() {
        precondition(OrcaTerminalContext.conversation([]) == nil)
        let long = String(repeating: "a", count: 5000) + "QUESTION?"
        let exchanges = (1...10).map { OrcaTerminalContext.Exchange(prompt: "prompt \($0)", reply: $0 == 10 ? long : "reply \($0)") }
        let rendered = OrcaTerminalContext.conversation(exchanges)!
        precondition(!rendered.contains("prompt 4\n") && rendered.hasPrefix("User: prompt 5"), "keeps the newest six, oldest first")
        precondition(rendered.hasSuffix("QUESTION?"), "latest reply keeps its end")
        precondition(rendered.count <= OrcaTerminalContext.maxConversationCharacters + 100)

        let big = String(repeating: "b", count: 3000)
        let heavy = (1...6).map { _ in OrcaTerminalContext.Exchange(prompt: big, reply: big) }
        let trimmed = OrcaTerminalContext.conversation(heavy)!
        precondition(trimmed.count <= OrcaTerminalContext.maxConversationCharacters, "\(trimmed.count)")
        precondition(trimmed.components(separatedBy: "User: ").count - 1 == 2, "budget stops at whole exchanges")

        let prompt = OrcaTerminalContext.headAndTail("START" + String(repeating: "x", count: 3000) + "END", limit: 1000)
        precondition(prompt.hasPrefix("START") && prompt.hasSuffix("END") && prompt.count <= 1003)
    }

    static func focusedPane() {
        let list: [String: Any] = [
            "terminals": [
                ["handle": "term_a", "tabId": "tab1", "leafId": "leaf1", "agentIdentity": "claude"],
                ["handle": "term_b", "tabId": "tab2", "leafId": "leaf2"],
            ],
            "visualLayouts": [
                ["worktreeId": "wt1", "root": ["type": "group", "activeTabId": "tab1", "tabs": [
                    ["tabId": "tab1", "activeLeafId": "leaf1"], ["tabId": "tab2", "activeLeafId": "leaf2"],
                ]]],
                ["worktreeId": "wt2", "root": ["type": "split", "children": [
                    ["type": "group", "activeTabId": "tab2", "tabs": [["tabId": "tab2", "activeLeafId": "leaf2"]]],
                    ["type": "group", "activeTabId": "tab1", "tabs": [["tabId": "tab1", "activeLeafId": "leaf1"]]],
                ]]],
            ],
        ]
        precondition(OrcaTerminalContext.focusedPane(activeWorktreeID: "wt1", terminalList: list)
            == .init(handle: "term_a", tabID: "tab1", leafID: "leaf1", agent: "claude"))
        precondition(OrcaTerminalContext.focusedPane(activeWorktreeID: "wt2", terminalList: list) == nil, "two tab groups: unknown focus")
        precondition(OrcaTerminalContext.focusedPane(activeWorktreeID: "missing", terminalList: list) == nil)
    }

    static func promptBlock() {
        precondition(OrcaTerminalContext.promptBlock(conversation: nil, typed: nil) == nil)
        let block = OrcaTerminalContext.promptBlock(conversation: "User: hi", typed: "so the")!
        precondition(block.contains("<recent_conversation>\nUser: hi\n</recent_conversation>"))
        precondition(block.hasSuffix("<already_typed>\nso the\n</already_typed>"))
        precondition(!OrcaTerminalContext.promptBlock(conversation: nil, typed: "x")!.contains("recent_conversation"))
    }
}
