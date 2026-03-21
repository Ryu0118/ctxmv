import CTXMVCLI
import Logging

/// Bootstraps logging and runs the root CLI command.
@main
struct CTXMVMain {
    static func main() async {
        LoggingSystem.bootstrap(logLevel: .info)
        await CTXMVCommand.main(nil)
    }
}
