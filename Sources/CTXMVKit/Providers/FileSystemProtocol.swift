import Foundation

/// Abstraction over file system operations for testability.
package protocol FileSystemProtocol: Sendable {
    var homeDirectoryForCurrentUser: URL { get }
    func fileExists(atPath path: String) -> Bool
    func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool
    func contents(atPath path: String) -> Data?
    @discardableResult
    func createFile(atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey: Any]?) -> Bool
    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey: Any]?) throws
    func contentsOfDirectory(atPath path: String) throws -> [String]
    func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions) throws -> [URL]
    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any]
}

/// Default adapter that forwards `FileSystemProtocol` calls to `FileManager`.
package struct DefaultFileSystem: FileSystemProtocol, Sendable {
    package init() {}

    package var homeDirectoryForCurrentUser: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    package func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    package func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        FileManager.default.fileExists(atPath: path, isDirectory: isDirectory)
    }

    package func contents(atPath path: String) -> Data? {
        FileManager.default.contents(atPath: path)
    }

    @discardableResult
    package func createFile(atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey: Any]?) -> Bool {
        FileManager.default.createFile(atPath: path, contents: data, attributes: attr)
    }

    package func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]?
    ) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates,
            attributes: attributes
        )
    }

    package func contentsOfDirectory(atPath path: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: path)
    }

    package func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions
    ) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: mask
        )
    }

    package func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        try FileManager.default.attributesOfItem(atPath: path)
    }
}
