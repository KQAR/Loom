import AppKit
import Foundation

/// Selects a file in Finder — used after exporting the CA so the human can drag
/// it straight into Keychain Access.
enum RevealInFinder {
    static func reveal(path: String) {
        let url = URL(fileURLWithPath: path)
        Task { @MainActor in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
