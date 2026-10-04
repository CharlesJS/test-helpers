//
//  DiskImageHelper_Darwin.swift
//
//
//  Created by Charles Srstka on 10/28/23.
//

#if canImport(Darwin)

import DiskArbitration
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

    public struct DADissenterError: Error {
        init(dissenter: DADissenter) {}
    }

    public struct MountedImage: Sendable {
        public let imageURL: URL
        public let mountPoint: URL
        public var rootDirectory: URL { self.mountPoint }
        public let devEntry: URL
        public let rootDevEntry: URL
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

    public func mountImage(url: URL, readOnly: Bool) throws -> MountedImage {
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

        var mountPoint: URL?
        var mountDevEntry: URL?
        var allDevEntries: [String] = []

        for eachEntity in try #require(dict["system-entities"] as? [[String : Any]]) {
            if let devEntry = eachEntity["dev-entry"] as? String {
                allDevEntries.append(devEntry)

                if let mountPointPath = eachEntity["mount-point"] as? String {
                    let mountPointURL = URL(fileURLWithPath: mountPointPath)
                    let devEntryURL = if #available(macOS 27.0, *) {
                        URL(filePath: "/dev/\(devEntry)")
                    } else {
                        URL(fileURLWithPath: devEntry)
                    }

                    mountPoint = mountPointURL
                    mountDevEntry = devEntryURL
                }
            }
        }

        guard let mountPoint, let mountDevEntry else {
            if #available(macOS 27.0, *) {
                throw DiskutilError(status: process.terminationStatus, stderr: stderr)
            } else {
                throw HdiutilError(status: process.terminationStatus, stderr: stderr)
            }
        }

        let rootDevEntry = try self.getRootEntry(allDevEntries)

        return MountedImage(imageURL: url, mountPoint: mountPoint, devEntry: mountDevEntry, rootDevEntry: rootDevEntry)
    }

    private func getRootEntry(_ devEntries: [String]) throws -> URL {
        let registryPaths = try devEntries.map {
            let matching = IOBSDNameMatching(kIOMainPortDefault, 0, $0)
            let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
            guard service != IO_OBJECT_NULL else { throw CocoaError(.fileReadUnknown) }
            defer { IOObjectRelease(service) }

            guard let path = IORegistryEntryCopyPath(service, kIOServicePlane) else { throw CocoaError(.fileReadUnknown) }
            return path.takeRetainedValue() as String
        }

        guard let root = zip(devEntries, registryPaths).first(where: { _, path in
            registryPaths.allSatisfy { $0 == path || $0.hasPrefix(path) }
        }) else {
            throw CocoaError(.fileReadUnknown)
        }

        return URL(fileURLWithPath: "/dev/\(root.0)")
    }

    public func unmountImage(_ image: MountedImage, timeout: CFTimeInterval = 300.0) throws {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let runLoop = CFRunLoopGetCurrent(),
              let partition = DADiskCreateFromBSDName(kCFAllocatorDefault, session, image.devEntry.lastPathComponent),
              let wholeDisk = DADiskCopyWholeDisk(partition),
              let rootDisk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, image.rootDevEntry.lastPathComponent),
              let wholeBSDName = DADiskGetBSDName(wholeDisk).map({ String(cString: $0) }) else {
            throw CocoaError(.fileReadUnknown)
        }

        enum Callbacks {
            static let unmount: DADiskUnmountCallback = {
                print("!!! unmounted: dissenter is \($1)")
                let ctx = Context.fromPointer($2!)

                if let dissenter = $1 {
                    ctx.error = DADissenterError(dissenter: dissenter)
                } else {
                    ctx.unmounted = true
                    print("!!! successfully unmounted")
                    DADiskEject(ctx.rootDisk, UInt32(kDADiskEjectOptionDefault), Callbacks.eject, $2)
                }
            }

            static let eject: DADiskEjectCallback = {
                let ctx = Context.fromPointer($2!)

                if let dissenter = $1 {
                    ctx.error = DADissenterError(dissenter: dissenter)
                } else {
                    print("!!! successfully ejected \(DADiskGetBSDName($0).map { String(cString: $0) }))")
                    ctx.ejected = true
                }
            }

            static let disappeared: DADiskDisappearedCallback = {
                print("!!! disappeared: \(DADiskGetBSDName($0).map { String(cString: $0) }))")
                let ctx = Context.fromPointer($1!)

                ctx.disappeared = true
            }
        }

        class Context {
            let rootDisk: DADisk

            var unmounted = false
            var ejected = false
            var disappeared = false
            var error: any Swift.Error? = nil

            static func fromPointer(_ ptr: UnsafeMutableRawPointer) -> Self {
                Unmanaged.fromOpaque(ptr).takeUnretainedValue()
            }
            var toPointer: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

            init(rootDisk: DADisk) { self.rootDisk = rootDisk }
        }

        let mode = "com.charlessoft.DiskImageHelper.waitForUnmount" as CFString
        DASessionScheduleWithRunLoop(session, runLoop, mode)
        defer { DASessionUnscheduleFromRunLoop(session, runLoop, mode) }

        let ctx = Context(rootDisk: rootDisk)

        let match = [kDADiskDescriptionMediaBSDNameKey : wholeBSDName] as CFDictionary
        DARegisterDiskDisappearedCallback(session, nil, Callbacks.disappeared, ctx.toPointer)

        let options = DADiskUnmountOptions(kDADiskUnmountOptionWhole | kDADiskUnmountOptionForce)
        DADiskUnmount(wholeDisk, options, Callbacks.unmount, ctx.toPointer)

        let timeoutDate = Date(timeIntervalSinceNow: timeout)
        while !ctx.disappeared, ctx.error == nil, Date() < timeoutDate {
            CFRunLoopRunInMode(CFRunLoopMode(mode), 0.1, true)
        }

        if let err = ctx.error {
            throw err
        }

        if !ctx.ejected || !ctx.disappeared {
            throw CocoaError(.fileReadUnknown)
        }
    }
}

#endif
