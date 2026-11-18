import Foundation

// The same binary is the app and the scheduled cleaner: launchd runs it with --cleanup.
if let exitCode = CleanupCLI.runIfRequested(CommandLine.arguments) {
    exit(exitCode)
}
JanitorApp.main()
