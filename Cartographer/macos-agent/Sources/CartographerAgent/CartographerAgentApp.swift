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
                // These two buttons act as a back-and-forth toggle across the
                // experiment: Copy starts the run (status "Working"), Mark
                // Ready aborts and re-arms it — exactly one is enabled at a
                // time, and Copy also requires a prompt to copy.
                Button("Copy Current Prompt") { agent.copyPrompt() }
                    .disabled(agent.currentPrompt == nil || agent.status == "Working")
                // Only useful mid-experiment: "copy prompt" kicked off the
                // run, but you decided not to proceed, so re-arm the agent.
                Button("Mark Ready") { agent.markReady() }
                    .disabled(agent.status != "Working")
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

/// Kicks off the agent loop once the app has finished launching, and makes
/// sure a normal exit (Quit button, Cmd+Q, or a SIGTERM/SIGINT from the
/// command line) tells the server the agent is shutting down cleanly.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await Agent.shared.start() }
        // Route termination signals onto the main queue (signal handlers may
        // not touch AppKit/URLSession directly), where a normal terminate()
        // runs and triggers applicationWillTerminate's farewell heartbeat.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)  // handled by the dispatch source below
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApplication.shared.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Agent.shared.farewell()
    }
}
