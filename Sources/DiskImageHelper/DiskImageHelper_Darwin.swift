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
    public struct DiskutilError: Error {
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
        case exfat = "exfat"
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
        public var isWritable: Bool { true }

        public var supportsPermissions: Bool {
            switch self {
            case .apfs, .hfsPlus, .udf: true
            case .exfat, .fat32: false
            }
        }

        public var supportsExtendedAttributes: Bool { true }

        public var supportsResourceFork: Bool {
            switch self {
            case .apfs, .hfsPlus: true
            default: false
            }
        }

        fileprivate var hdiutilArgument: String {
            switch self {
            case .apfs: "APFS"
            case .exfat: "ExFAT"
            case .fat32: "FAT32"
            case .hfsPlus: "HFS+"
            case .udf: "UDF"
            }
        }

        fileprivate var diskutilArgument: String? {
            switch self {
            case .apfs: "APFS"
            case .exfat: "ExFAT"
            case .fat32: "MS-DOS"
            default: nil
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
        let stdoutPipe = Pipe()
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrPipe = Pipe()
        let diskutilFS = fileSystem.diskutilArgument
        let hdiutilFS = fileSystem.hdiutilArgument

        if #available(macOS 27.0, *), let fs = diskutilFS {
            let path = url.path(percentEncoded: false)

            process.executableURL = URL(filePath: "/usr/sbin/diskutil")
            process.arguments = [
                "image", "create", "blank", "--size", "\(size)", "--fs", fs, "--volumeName", fs, path, "--plist"
            ]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = ["create", "-size", "\(size)b", "-fs", hdiutilFS, "-volname", hdiutilFS, url.path, "-plist"]
        }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        if #available(macOS 27.0, *), diskutilFS != nil {
            guard let stdout = try stdoutHandle.readToEnd(),
                  let dict = try PropertyListSerialization.propertyList(from: stdout, format: nil) as? [String : Any],
                  let path = dict["image-path"] as? String else {
                throw DiskutilError(status: process.terminationStatus, stderr: stderrPipe)
            }

            return URL(filePath: path)
        } else {
            guard let stdout = try stdoutHandle.readToEnd(),
                  let array = try PropertyListSerialization.propertyList(from: stdout, format: nil) as? [String],
                  array.count == 1,
                  let path = array.first else {
                throw HdiutilError(status: process.terminationStatus, stderr: stderrPipe)
            }

            return URL(fileURLWithPath: path)
        }
    }

    public func mountImage(url: URL, readOnly: Bool) throws -> (mountPoint: URL, rootDirectory: URL, devEntry: URL) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        var args: [String] = []

        if #available(macOS 27.0, *) {
            args = ["image", "attach", url.path(percentEncoded: false), "--plist"]
            if readOnly {
                args.append("--readOnly")
            }

            process.executableURL = URL(filePath: "/usr/sbin/diskutil")
        } else {
            args = ["attach", url.path, "-plist"]
            if readOnly {
                args.append("-readonly")
            }

            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        }
        process.arguments = args
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let data = try stdout.fileHandleForReading.readToEnd(),
              let dict = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String : Any] else {
            if #available(macOS 27.0, *) {
                throw DiskutilError(status: process.terminationStatus, stderr: stderr)
            } else {
                throw HdiutilError(status: process.terminationStatus, stderr: stderr)
            }
        }

        for eachEntity in try #require(dict["system-entities"] as? [[String : Any]]) {
            if let mountPoint = eachEntity["mount-point"] as? String, let devEntry = eachEntity["dev-entry"] as? String {
                let mountPointURL = URL(fileURLWithPath: mountPoint)

                return (mountPoint: mountPointURL, rootDirectory: mountPointURL, devEntry: URL(fileURLWithPath: devEntry))
            }
        }

        if #available(macOS 27.0, *) {
            throw DiskutilError(status: process.terminationStatus, stderr: stderr)
        } else {
            throw HdiutilError(status: process.terminationStatus, stderr: stderr)
        }
    }

    public func unmountImage(mountPoint: URL, devEntry: URL) throws {
        let process = Process()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["eject", devEntry.path]
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw DiskutilError(status: process.terminationStatus, stderr: stderr)
        }

        let deadline = Date().addingTimeInterval(10.0)
        while Date() < deadline, (try? mountPoint.checkResourceIsReachable()) == true {
            usleep(100000)
        }
    }
}

#endif
