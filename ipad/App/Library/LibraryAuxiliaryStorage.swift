import Foundation

struct LibraryAuxiliaryStorage: Sendable {
    var galleryBytes: Int64 = 0
    var workspaceBytes: Int64 = 0
    var configurationBytes: Int64 = 0

    static func scan(appRoot: URL) throws -> Self {
        try Task.checkCancellation()
        guard try properties(of: appRoot)?.isDirectory == true else { return Self() }

        let gallery = appRoot.appending(path: "GeneratedImages", directoryHint: .isDirectory)
        let catalog = appRoot.appending(path: "library.json", directoryHint: .notDirectory)
        let readerAI = appRoot.appending(path: "ReaderAI", directoryHint: .isDirectory)
        var storage = Self()
        storage.galleryBytes = try size(of: children(in: gallery))
        if let properties = try properties(of: catalog), properties.isRegularFile == true {
            storage.configurationBytes = Int64(properties.fileSize ?? 0)
        }
        for child in try children(in: readerAI) {
            try Task.checkCancellation()
            if child.lastPathComponent == "Workspace" {
                storage.workspaceBytes = try size(of: children(in: child))
            } else {
                storage.configurationBytes += try size(of: [child])
            }
        }
        return storage
    }

    private static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]

    private static func size(of urls: [URL]) throws -> Int64 {
        var remaining = urls
        var bytes: Int64 = 0
        while let url = remaining.popLast() {
            try Task.checkCancellation()
            guard let properties = try properties(of: url) else { continue }
            if properties.isRegularFile == true {
                bytes += Int64(properties.fileSize ?? 0)
            } else if properties.isDirectory == true {
                remaining.append(contentsOf: try children(in: url))
            }
        }
        return bytes
    }

    private static func properties(of url: URL) throws -> URLResourceValues? {
        do {
            let values = try url.resourceValues(forKeys: keys)
            return values.isSymbolicLink == true ? nil : values
        } catch where isMissing(error) {
            return nil
        }
    }

    private static func children(in url: URL) throws -> [URL] {
        guard try properties(of: url)?.isDirectory == true else { return [] }
        do {
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys))
        } catch where isMissing(error) {
            return []
        }
    }

    private static func isMissing(_ error: Error) -> Bool {
        let failure = error as NSError
        return (failure.domain == NSCocoaErrorDomain
            && [CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue].contains(failure.code))
            || (failure.domain == NSPOSIXErrorDomain && failure.code == Int(POSIXErrorCode.ENOENT.rawValue))
    }
}
