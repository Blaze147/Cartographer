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
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(Config.self, from: data)
    }

    var baseURL: URL {
        URL(string: serverUrl)!
    }
}
