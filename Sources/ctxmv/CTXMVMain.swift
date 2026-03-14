import CTXMVCLI
import Foundation
import Logging

@main
/// Bootstraps logging and runs the root CLI command.
struct CTXMVMain {
    static func main() async {
        // Enable line buffering so log output appears immediately.
        setlinebuf(FileHandle.standardOutput.fileDescriptor)
        LoggingSystem.bootstrap(logLevel: .info)
        await CTXMVCommand.main(nil)
    }

    /// Sets line buffering on a file descriptor via fdopen + setvbuf.
    private static func setlinebuf(_ fd: Int32) {
        guard let stream = fdopen(fd, "w") else { return }
        setvbuf(stream, nil, _IOLBF, 0)
    }
}
