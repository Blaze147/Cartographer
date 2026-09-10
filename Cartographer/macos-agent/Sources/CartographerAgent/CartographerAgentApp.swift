import SwiftUI
import AppKit

@main
struct CartographerAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var agent = Agent.shared

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 8) {
                Text("Cartographer").font(.headline)
                Divider()
                HStack { Text("Status:"); Text(agent.status) }
                HStack { Text("Harness:"); Text(agent.configHarness) }
                HStack { Text("Branch:"); Text(agent.branch).font(.system(.body, design: .monospaced)) }
                if let err = agent.lastError {
                    Divider()
                    Text("Error: \(err)").foregroundColor(.red).font(.caption)
                }
                Divider()
                Button("Copy Current Prompt") { agent.copyPrompt() }
                    .disabled(agent.currentPrompt == nil)
                Button("Open Dashboard") { agent.openDashboard() }
                Button("Refresh") { Task { await agent.refresh() } }
                Divider()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .padding()
            .frame(width: 320)
        } label: {
            Image(systemName: agent.iconName)
                .foregroundColor(agent.iconColor)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Kicks off the agent loop once the app has finished launching.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await Agent.shared.start() }
    }
}
