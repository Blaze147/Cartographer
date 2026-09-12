import Foundation

/// Local agent configuration. Each Mac has its own config file.
struct Config: Codable {
    var machineId: String
    var harness: String
    var repositoryPath: String
    var serverUrl: String
    var apiKey: String

    static func load() throws -> Config {
        let path = ProcessInfo.processInfo.environment["CARTOGRAPHER_CONFIG"]
            ?? NSHomeDirectory() + "/.cartographer/config.json"
        let url = URL(fileURLWithPath: path)

        // First run on this machine: scaffold a config file so a fresh
        // install just works. The generated ids are placeholders meant to be
        // edited once; the file is only ever written here, never overwritten
        // when it (or a user's customization) already exists.
        if !FileManager.default.fileExists(atPath: path) {
            let n = UInt32.random(in: 1000...9999)
            let fresh = Config(
                machineId: "new-machine-\(n)",
                harness: "new-harness-\(n)",
                // Expanded to an absolute path so git/runs work without "~"
                // support; keep "~" out of the stored value.
                repositoryPath: NSHomeDirectory() + "/repos/Pathfinder",
                serverUrl: "http://127.0.0.1:5080",
                apiKey: "")
            let dir = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent)
            try FileManager.default.createDirectory(at: dir,
                                                    withIntermediateDirectories: true)
            let json = JSONEncoder()
            json.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try json.encode(fresh).write(to: url, options: [.atomic])
            return fresh
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Config.self, from: data)
    }

    var baseURL: URL {
        URL(string: serverUrl)!
    }
}
