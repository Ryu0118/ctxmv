import Foundation

/// Provides efficient file reads with test-friendly fallbacks.
enum FileSystemProvider {
    /// Read the first `maxBytes` of a file. Uses FileHandle for efficiency;
    /// falls back to full read via FileSystemProtocol for mock file systems.
    static func readHead(fileSystem: FileSystemProtocol, file: URL, maxBytes: Int) throws -> Data {
        // Fast path: direct FileHandle read (avoids loading entire file)
        if canUseNativeFileHandle(with: fileSystem), let handle = try? FileHandle(forReadingFrom: file) {
            defer { handle.closeFile() }
            return handle.readData(ofLength: maxBytes)
        }
        // Fallback for mock file systems
        guard let data = fileSystem.contents(atPath: file.path) else {
            throw ProviderError.cannotReadFile(file.path)
        }
        return data.prefix(maxBytes)
    }

    /// Read the last `maxBytes` of a file. Uses FileHandle seek for efficiency;
    /// falls back to full read via FileSystemProtocol for mock file systems.
    static func readTail(fileSystem: FileSystemProtocol, file: URL, maxBytes: Int) throws -> Data {
        // Fast path: direct FileHandle seek (avoids loading entire file)
        if canUseNativeFileHandle(with: fileSystem), let handle = try? FileHandle(forReadingFrom: file) {
            defer { handle.closeFile() }
            let fileSize = handle.seekToEndOfFile()
            let offset = fileSize > UInt64(maxBytes) ? fileSize - UInt64(maxBytes) : 0
            handle.seek(toFileOffset: offset)
            return handle.readDataToEndOfFile()
        }
        // Fallback for mock file systems
        guard let data = fileSystem.contents(atPath: file.path) else {
            throw ProviderError.cannotReadFile(file.path)
        }
        return data.suffix(maxBytes)
    }

    /// Get file modification date via FileSystemProtocol.
    static func fileModificationDate(_ file: URL, fileSystem: FileSystemProtocol) -> Date? {
        guard let attributes = try? fileSystem.attributesOfItem(atPath: file.path) else { return nil }
        return attributes[.modificationDate] as? Date
    }

    /// Get file size without loading the full file into memory.
    static func fileSize(_ file: URL, fileSystem: FileSystemProtocol) -> Int64? {
        if canUseNativeFileHandle(with: fileSystem), let handle = try? FileHandle(forReadingFrom: file) {
            defer { handle.closeFile() }
            return Int64(handle.seekToEndOfFile())
        }

        guard let attributes = try? fileSystem.attributesOfItem(atPath: file.path) else { return nil }
        if let number = attributes[.size] as? NSNumber { return number.int64Value }
        if let size = attributes[.size] as? Int64 { return size }
        if let size = attributes[.size] as? Int { return Int64(size) }
        return nil
    }

    private static func canUseNativeFileHandle(with fileSystem: FileSystemProtocol) -> Bool {
        fileSystem is DefaultFileSystem || fileSystem is FileManager
    }
}
