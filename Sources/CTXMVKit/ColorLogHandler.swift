import Foundation
import Logging
import Rainbow

package extension Logger.MetadataValue {
    /// Stores a `Rainbow` color in logger metadata using its raw ANSI code.
    static func color(_ color: NamedColor) -> Self {
        .stringConvertible(color.rawValue)
    }
}

package extension Logger.Metadata {
    /// Namespaces the log color under the single metadata key understood by `ColorLogHandler`.
    static func color(_ color: NamedColor) -> Self { ["color": .color(color)] }
}

/// Writes colored log messages to standard output.
package struct ColorLogHandler: LogHandler, Sendable {
    package var metadata: Logger.Metadata = [:]
    package var logLevel: Logger.Level = .info

    package init(label _: String) {}

    package subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    package func log(
        level _: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source _: String,
        file _: String,
        function _: String,
        line _: UInt
    ) {
        let color: NamedColor?
        if let metadata,
           let rawColorString = metadata["color"],
           let colorCode = UInt8(rawColorString.description),
           let namedColor = NamedColor(rawValue: colorCode)
        {
            // Logging metadata is stringly typed, so decode the stored ANSI value
            // back into Rainbow's enum before rendering.
            color = namedColor
        } else {
            color = nil
        }

        let renderedMessage = if let color {
            message.description.applyingColor(color)
        } else {
            message.description
        }
        print(renderedMessage)
    }
}

public extension LoggingSystem {
    /// Boots the global logging system with ctxmv's colored stdout handler.
    static func bootstrap(logLevel: Logger.Level) {
        bootstrap { _ in
            var handler = ColorLogHandler(label: "ctxmv")
            handler.logLevel = logLevel
            return handler
        }
    }
}
