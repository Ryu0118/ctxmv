import Foundation
import Logging
import Rainbow

package extension Logger.MetadataValue {
    static func color(_ color: NamedColor) -> Self {
        .stringConvertible(color.rawValue)
    }
}

package extension Logger.Metadata {
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

    // swiftlint:disable:next function_parameter_count
    package func log(
        level _: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source _: String,
        file _: String,
        function _: String,
        line _: UInt
    ) {
        let color: NamedColor? = if let metadata,
                                    let rawColorString = metadata["color"],
                                    let colorCode = UInt8(rawColorString.description),
                                    let namedColor = NamedColor(rawValue: colorCode)
        {
            namedColor
        } else {
            nil
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
    static func bootstrap(logLevel: Logger.Level) {
        bootstrap { _ in
            var handler = ColorLogHandler(label: "ctxmv")
            handler.logLevel = logLevel
            return handler
        }
    }
}
