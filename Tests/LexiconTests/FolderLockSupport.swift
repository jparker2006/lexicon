import Foundation

/// Opens a folder's History again once the store before it has let the folder's lock go. A
/// dropped store finishes its release on whichever thread lets go of it last, and its lock closes
/// only at the end of that, so a test that reopens a folder waits on the lock itself. Any other
/// error is thrown at once, and the test's time limit ends the wait (the sleep is cancelled).
nonisolated(nonsending) func onceFolderIsFree<T>(_ open: () throws -> T) async throws -> T {
    while true {
        do {
            return try open()
        } catch let error as POSIXError where error.code == .EWOULDBLOCK {
            try await Task.sleep(for: .milliseconds(5))  // timing-ok: a poll interval; it decides nothing
        }
    }
}
