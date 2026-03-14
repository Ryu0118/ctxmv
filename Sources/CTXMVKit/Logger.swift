import Foundation
import Logging

/// Single shared logger for all of ctxmv.
package nonisolated(unsafe) var logger = Logger(label: "ctxmv")
