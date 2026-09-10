import Foundation
import AppKit
import SwiftUI

/// A server command as returned by GET /api/agents/{machineId}/command.
struct ServerCommand: Codable {
    var id: String
    var type: String
    var baseline: String?
    var taskNumber: Int
    var attemptNumber: Int
    var prompt: String?
    var branchName: String?
}

/// Collected Git statistics sent back for a collect command.
struct RunData: Codable {
    var machineId: String
    var harness: String
    var branch: String
    var baseline: String
    var taskNumber: Int
    var attemptNumber: Int
    var commitSha: String
    var filesChanged: Int
    var filesAdded: Int
    var filesModified: Int
    var filesDeleted: Int
    var linesAdded: Int
    var linesDeleted: Int
    var renameCount: Int
    var changedFiles: [String]
    var diff: String
}

/// The agent's state machine. Runs in the background and drives the menu bar.
@MainActor
final class Agent: ObservableObject {
    static let shared = Agent()

    @Published var status = "Starting"
    @Published var branch = ""
    @Published var lastError: String?
    @Published var currentPrompt: String?

    private var config: Config?
    private var processed = Set<String>()
    private var repoDir = ""

    /// Menu-bar icon reflects the agent state: green ready, orange working,
    /// red error, gray idle.
    var iconName: String {
        switch status {
        case "Ready", "Collected": return "checkmark.circle.fill"
        case "Preparing", "Collecting": return "arrow.triangle.2.circlepath"
        case "Error", "Offline": return "exclamationmark.triangle.fill"
        default: return "circle"
        }
    }

    var iconColor: Color {
        switch status {
        case "Ready", "Collected": return .green
        case "Preparing", "Collecting": return .orange
        case "Error", "Offline": return .red
        default: return .gray
        }
    }

    var configHarness: String { config?.harness ?? "—" }

    /// Copy the current experiment prompt to the clipboard.
    func copyPrompt() {
        if let prompt = currentPrompt {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(prompt, forType: .string)
        }
    }

    func openDashboard() {
        if let url = config?.baseURL {
            NSWorkspace.shared.open(url)
        }
    }

    /// Force an immediate poll cycle.
    func refresh() async {
        await runOnce()
    }

    func start() async {
        // Tiny local record of commands we have already handled, so a command
        // is never executed twice even if the server repeats it.
        processed = Set(Array(UserDefaults.standard.stringArray(forKey: "processedCommands") ?? []))

        do {
            config = try Config.load()
            repoDir = config!.repositoryPath
            status = "Idle"
        } catch {
            status = "Error"
            lastError = "Cannot load config: \(error.localizedDescription)"
            return
        }

        while !Task.isCancelled {
            await runOnce()
            try? await Task.sleep(nanoseconds: sleepInterval())
        }
    }

    private func sleepInterval() -> UInt64 {
        // Poll faster while there is an active experiment, slower when idle.
        return (status == "Idle" || status == "Ready") ? 30_000_000_000 : 5_000_000_000
    }

    private func runOnce() async {
        guard config != nil else { return }
        await heartbeat()
        await processCommandIfAny()
    }

    // ---- HTTP helpers -------------------------------------------------

    private func request(_ path: String, _ method: String = "GET",
                         body: Encodable? = nil) async throws -> (Data, URLResponse) {
        let config = config!
        var req = URLRequest(url: URL(string: path, relativeTo: config.baseURL)!)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            req.setValue(config.apiKey, forHTTPHeaderField: "X-Api-Key")
        }
        if let body {
            req.httpBody = try JSONEncoder().encode(body)
        }
        return try await URLSession.shared.data(for: req)
    }

    // ---- Heartbeat ----------------------------------------------------

    private func heartbeat() async {
        guard let config else { return }
        struct HB: Encodable {
            var machineId: String, harness: String, repositoryPath: String
            var branch: String, state: String, lastError: String?
        }
        let body = HB(machineId: config.machineId, harness: config.harness,
                      repositoryPath: repoDir, branch: branch, state: status,
                      lastError: lastError)
        _ = try? await request("/api/agents/\(config.machineId)/heartbeat", "POST", body: body)
    }

    // ---- Command processing -------------------------------------------

    private func processCommandIfAny() async {
        guard let config else { return }
        do {
            let (data, _) = try await request("/api/agents/\(config.machineId)/command")
            let cmd = try JSONDecoder().decode(ServerCommand.self, from: data)
            // Empty id means the server returned a no-op placeholder.
            guard !cmd.id.isEmpty, !processed.contains(cmd.id) else {
                // The server is reachable with nothing to do: clear any
                // transient reachability error so a fresh launch (or a brief
                // blip) doesn't leave the agent stuck showing "Error".
                if status == "Error" {
                    status = "Idle"
                    lastError = nil
                }
                return
            }
            processed.insert(cmd.id)
            UserDefaults.standard.set(Array(processed), forKey: "processedCommands")
            await handle(cmd)
        } catch {
            status = "Error"
            lastError = "Cannot reach server: \(error.localizedDescription)"
        }
    }

    private func handle(_ cmd: ServerCommand) async {
        status = cmd.type == "prepare" ? "Preparing" : "Collecting"
        lastError = nil
        do {
            if cmd.type == "prepare" {
                try prepare(cmd)
                status = "Ready"
                branch = cmd.branchName ?? ""
                currentPrompt = cmd.prompt
                await sendResult(cmd.id, success: true)
            } else if cmd.type == "collect" {
                let run = try collect(cmd)
                status = "Collected"
                await sendResult(cmd.id, success: true, run: run)
            }
        } catch {
            status = "Error"
            lastError = error.localizedDescription
            await sendResult(cmd.id, success: false, error: error.localizedDescription)
        }
    }

    private func sendResult(_ commandId: String, success: Bool,
                            error: String? = nil, run: RunData? = nil) async {
        guard let config else { return }
        struct Body: Encodable {
            var commandId: String
            var success: Bool
            var error: String?
            var run: RunData?
        }
        _ = try? await request("/api/agents/\(config.machineId)/command-result", "POST",
                               body: Body(commandId: commandId, success: success, error: error, run: run))
    }

    // ---- Git helpers --------------------------------------------------

    @discardableResult
    private func git(_ args: [String], at dir: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        let out = Pipe(); let err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        p.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            throw GitError((stderr.isEmpty ? stdout : stderr).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct GitError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    private func ensureRepoExists() throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repoDir, isDirectory: &isDir), isDir.boolValue else {
            throw GitError("Repository path does not exist: \(repoDir)")
        }
    }

    private func workingTreeIsClean() throws -> Bool {
        return try git(["status", "--porcelain"], at: repoDir).isEmpty
    }

    // ---- Prepare ------------------------------------------------------

    private func prepare(_ cmd: ServerCommand) throws {
        try ensureRepoExists()
        guard let baseline = cmd.baseline, let branchName = cmd.branchName else {
            throw GitError("Prepare command missing baseline or branch name.")
        }

        // Fetch remote tags if there is a remote; ignore if not a clone.
        _ = try? git(["fetch", "--tags", "--prune"], at: repoDir)

        // Verify the baseline tag resolves to a commit.
        _ = try git(["rev-parse", "--verify", "\(baseline)^{commit}"], at: repoDir)

        // Refuse to touch a dirty tree.
        guard try workingTreeIsClean() else {
            throw GitError("Working tree has unexpected changes. Commit or stash them before preparing.")
        }

        // The branch should not already exist.
        let exists = (try? git(["rev-parse", "--verify", "--verify", branchName], at: repoDir)) != nil
        guard !exists else {
            throw GitError("Branch \(branchName) already exists unexpectedly.")
        }

        // Create the experiment branch at the baseline commit and check it out.
        _ = try git(["checkout", "-b", branchName, baseline], at: repoDir)

        // Verify we are now on the intended branch.
        let current = try git(["branch", "--show-current"], at: repoDir)
        guard current == branchName else {
            throw GitError("Unexpected branch after prepare: \(current)")
        }
    }

    // ---- Collect ------------------------------------------------------

    private func collect(_ cmd: ServerCommand) throws -> RunData {
        try ensureRepoExists()
        guard let baseline = cmd.baseline else {
            throw GitError("Collect command missing baseline.")
        }

        guard try workingTreeIsClean() else {
            throw GitError("Repository is not clean. Stage and commit all experiment changes before collecting.")
        }

        let branch = try git(["branch", "--show-current"], at: repoDir)
        let head = try git(["rev-parse", "HEAD"], at: repoDir)

        // name-status: "M\tfile", "A\tfile", "D\tfile", "R100\told\tnew"
        let nameStatus = try git(["diff", "--name-status", baseline, "HEAD"], at: repoDir)
        var added = 0, modified = 0, deleted = 0, renames = 0
        var files: [String] = []
        for line in nameStatus.components(separatedBy: "\n").filter({ !$0.isEmpty }) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: true)
            guard let code = parts.first else { continue }
            let file = parts.count > 1 ? String(parts[parts.count - 1]) : ""
            switch code.first {
            case "A": added += 1; files.append(file)
            case "D": deleted += 1; files.append(file)
            case "R": renames += 1; files.append(file)
            default: modified += 1; files.append(file)
            }
        }

        // numstat: "adds\tdeletes\tfile"
        let numstat = try git(["diff", "--numstat", baseline, "HEAD"], at: repoDir)
        var linesAdded = 0, linesDeleted = 0
        for line in numstat.components(separatedBy: "\n").filter({ !$0.isEmpty }) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }
            linesAdded += Int(parts[0]) ?? 0
            linesDeleted += Int(parts[1]) ?? 0
        }

        let diff = try git(["diff", baseline, "HEAD"], at: repoDir)

        let config = config!
        return RunData(
            machineId: config.machineId, harness: config.harness, branch: branch,
            baseline: baseline, taskNumber: cmd.taskNumber, attemptNumber: cmd.attemptNumber,
            commitSha: head, filesChanged: added + modified + deleted,
            filesAdded: added, filesModified: modified, filesDeleted: deleted,
            linesAdded: linesAdded, linesDeleted: linesDeleted, renameCount: renames,
            changedFiles: files, diff: diff)
    }
}
