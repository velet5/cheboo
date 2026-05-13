import Foundation
import OSLog

/// Centralized `os.Logger` instances. Subsystem matches the bundle id so
/// `log stream --predicate 'subsystem == "com.github.velet5.cheboo"'` in
/// Terminal (or `Console.app` filtered the same way) surfaces the app's
/// signal without app activity from the rest of the system drowning it out.
enum Log {
    private static let subsystem = "com.github.velet5.cheboo"

    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let dictation = Logger(subsystem: subsystem, category: "dictation")
    static let socket = Logger(subsystem: subsystem, category: "socket")
    static let whisper = Logger(subsystem: subsystem, category: "whisper")
    static let settings = Logger(subsystem: subsystem, category: "settings")
}
