import Foundation
import os

/// Moves an old journal database (`<user>.sqlite`, from before databases
/// were named per sign-in) to its new name, without ever splitting the
/// database from its write-ahead log.
///
/// Committed changes can sit only in the `-wal` file, and the offline
/// outbox lives in the same database, so a database opened without its
/// `-wal` can lose unsent messages. The move therefore:
///
/// - moves `-wal` and `-shm` first and the main file last, so the old main
///   file stays put until everything else has moved;
/// - finishes an interrupted move on the next launch: while the old main
///   file is still there, any side file already at the new name counts as
///   moved;
/// - stops on the first error, puts every side file at the new name back
///   beside the old main file, and tells the caller to open the old file
///   for now, so the next launch tries again;
/// - if a side file cannot be put back either, opens neither file: the
///   caller runs on an in-memory database for that launch and leaves both
///   files alone, and the next launch finishes the move.
public enum LegacyStoreFileMove {
    static let sideSuffixes = ["-wal", "-shm"]
    private static let logger = os.Logger(subsystem: "chat.matron", category: "journal-store")

    /// Returns the database file to open: `target` once the old file has
    /// moved (or there was none), `legacy` if the move could not finish,
    /// or nil (open in memory) if the old file could not be made whole.
    @discardableResult
    public static func adopt(
        legacy: URL,
        target: URL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        move: (String, String) throws -> Void = { try FileManager.default.moveItem(atPath: $0, toPath: $1) }
    ) -> URL? {
        // No old database: nothing to move.
        guard fileExists(legacy.path) else { return target }
        // A database already sits at the new name. The main file moves last,
        // so this move never leaves one behind; leave both alone rather than
        // overwrite a database that is in use.
        guard !fileExists(target.path) else { return target }

        let steps = sideSuffixes.map { (legacy.path + $0, target.path + $0) } + [(legacy.path, target.path)]
        for (from, to) in steps where fileExists(from) {
            do {
                try move(from, to)
            } catch {
                logger.error("could not move the old journal database: \(error.localizedDescription, privacy: .public)")
                // Put back every side file that has moved, in this launch or
                // an interrupted one, so the old database opens whole.
                for suffix in sideSuffixes where fileExists(target.path + suffix) && !fileExists(legacy.path + suffix) {
                    do {
                        try move(target.path + suffix, legacy.path + suffix)
                    } catch {
                        logger.error("could not put back the old journal database's \(suffix, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        return nil
                    }
                }
                return legacy
            }
        }
        return target
    }
}
