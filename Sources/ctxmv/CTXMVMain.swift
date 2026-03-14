import CTXMVCLI
import Logging

@main
/// Bootstraps logging and runs the root CLI command.
struct CTXMVMain {
    static func main() async {
        LoggingSystem.bootstrap(logLevel: .info)
        await CTXMVCommand.main(nil)
    }
}
