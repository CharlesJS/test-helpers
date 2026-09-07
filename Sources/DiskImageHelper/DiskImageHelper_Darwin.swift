//
//  DiskImageHelper_Darwin.swift
//
//
//  Created by Charles Srstka on 10/28/23.
//

#if canImport(Darwin)

import Foundation
import Testing

@available(macOS 10.15.4, *)
public struct DiskImageHelper: Sendable {
    public struct HdiutilError: Error {
        let status: Int32
        let stderr: String

        init(status: Int32, stderr: Pipe) {
            self.status = status

            if let data = try? stderr.fileHandleForReading.readToEnd(),
               let err = String(data: data, encoding: .utf8) {
                self.stderr = err
            } else {
                self.stderr = "(unknown)"
            }
        }
    }

    public enum FileSystem: String, CaseIterable, Codable, Sendable {
        case apfs = "apfs"
        case exFat = "exfat"
        case fat32 = "fat32"
        case hfsPlus = "hfs+"
        case udf = "udf"

        public init?(name: String) { self.init(rawValue: name) }

        public var name: String { self.rawValue }

        public var osName: String {
            switch self {
            case .fat32: "msdos"
            case .hfsPlus: "hfs"
            default: self.name
            }
        }

        public var minimumSize: Int { 1024 * 1024 }

        public var supportsResourceFork: Bool {
            switch self {
            case .apfs, .hfsPlus: true
            default: false
            }
        }

        fileprivate var hdiutilArgument: String {
            switch self {
            case .apfs: "APFS"
            case .exFat: "ExFAT"
            case .fat32: "FAT32"
            case .hfsPlus: "HFS+"
            case .udf: "UDF"
            }
        }
    }

    public static let shared = Self.init()

    public let writableFileSystems = FileSystem.allCases

    public func createDiskImage(at url: URL, size: Int, fileSystem: FileSystem) throws -> URL {
        if (try? url.deletingLastPathComponent().checkResourceIsReachable()) != true {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        let process = Process()
        let stdout = Pipe()
        let stdoutHandle = stdout.fileHandleForReading
        let stderr = Pipe()
        let fs = fileSystem.hdiutilArgument

        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["create", "-size", "\(size)b", "-fs", fs, "-volname", fs, url.path, "-plist"]
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        guard let stdout = try stdoutHandle.readToEnd(),
              let array = try PropertyListSerialization.propertyList(from: stdout, format: nil) as? [String],
              array.count == 1,
              let path = array.first else {
            throw HdiutilError(status: process.terminationStatus, stderr: stderr)
        }

        return URL(fileURLWithPath: path)
    }

    public func mountImage(url: URL, readOnly: Bool) throws -> (mountPoint: URL, rootDirectory: URL, devEntry: URL) {
        let hdiutil = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        var args = ["attach", url.path, "-plist"]
        if readOnly {
            args.append("-readonly")
        }

        hdiutil.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        hdiutil.arguments = args
        hdiutil.standardOutput = stdout
        hdiutil.standardError = stderr

        try hdiutil.run()
        hdiutil.waitUntilExit()

        guard hdiutil.terminationStatus == 0,
              let data = try stdout.fileHandleForReading.readToEnd(),
              let dict = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String : Any] else {
            throw HdiutilError(status: hdiutil.terminationStatus, stderr: stderr)
        }

        for eachEntity in try #require(dict["system-entities"] as? [[String : Any]]) {
            if let mountPoint = eachEntity["mount-point"] as? String, let devEntry = eachEntity["dev-entry"] as? String {
                let mountPointURL = URL(fileURLWithPath: mountPoint)

                return (mountPoint: mountPointURL, rootDirectory: mountPointURL, devEntry: URL(fileURLWithPath: devEntry))
            }
        }

        throw HdiutilError(status: hdiutil.terminationStatus, stderr: stderr)
    }

    public func unmountImage(mountPoint: URL, devEntry: URL) throws {
        let hdiutil = Process()
        let stderr = Pipe()

        hdiutil.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        hdiutil.arguments = ["detach", devEntry.path]
        hdiutil.standardError = stderr

        try hdiutil.run()
        hdiutil.waitUntilExit()

        guard hdiutil.terminationStatus == 0 else {
            throw HdiutilError(status: hdiutil.terminationStatus, stderr: stderr)
        }

        let deadline = Date().addingTimeInterval(10.0)
        while Date() < deadline, (try? mountPoint.checkResourceIsReachable()) == true {
            usleep(100000)
        }
    }
}

#endif
