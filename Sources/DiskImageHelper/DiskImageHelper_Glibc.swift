//
//  DiskImageHelper_Darwin.swift
//
//
//  Created by Charles Srstka on 10/28/23.
//

#if canImport(Glibc)

import Foundation
import Glibc
import LZFSE
import SystemPackage
import Testing

public struct DiskImageHelper: Sendable {
    public enum Error: Swift.Error, Sendable {
        case readOnlyFileSystem(FileSystem)
    }

    public enum FileSystem: String, CaseIterable, Codable, Sendable {
        case apfs = "apfs"
        case exfat = "exfat"
        case ext2 = "ext2"
        case ext3 = "ext3"
        case ext4 = "ext4"
        case fat32 = "fat32"
        case hfsPlus = "hfs+"
        case udf = "udf"

        public init?(name: String) { self.init(rawValue: name) }

        private static let fsByOSName = Self.allCases.reduce(into: [:]) { $0[$1.osName] = $1 }
        public init?(osName: String) {
            guard let fs = Self.fsByOSName[osName] else { return nil }
            self = fs
        }

        public var name: String { self.rawValue }

        public var osName: String {
            switch self {
            case .fat32: "vfat"
            case .hfsPlus: "hfsplus"
            default: self.name
            }
        }

        public var minimumSize: Int {
            switch self {
            case .ext2, .fat32, .hfsPlus, .udf: 1024 * 1024
            case .apfs, .ext3, .ext4: 8 * 1024 * 1024
            case .exfat: 16 * 1024 * 1024
            }
        }

        public var supportsResourceFork: Bool {
            switch self {
            case .apfs, .hfsPlus: true
            default: false
            }
        }

        fileprivate var mkfsCommand: URL? {
            switch self {
            case .apfs, .hfsPlus: nil
            case .ext2: URL(filePath: "/usr/sbin/mkfs.ext2")
            case .ext3: URL(filePath: "/usr/sbin/mkfs.ext3")
            case .ext4: URL(filePath: "/usr/sbin/mkfs.ext4")
            case .exfat: URL(filePath: "/usr/sbin/mkfs.exfat")
            case .fat32: URL(filePath: "/usr/sbin/mkfs.fat")
            case .udf: URL(filePath: "/usr/sbin/mkfs.udf")
            }
        }

        fileprivate var mkfsArguments: [String] {
            switch self {
            case .exfat: ["-b", "4K", "-c", "4K"]
            default: []
            }
        }

        fileprivate var mountCommand: URL {
            switch self {
            case .exfat, .ext2, .ext3, .ext4, .fat32, .udf: Tools.mount
            case .apfs: URL(filePath: "/usr/bin/fsapfsmount")
            case .hfsPlus: URL(filePath: "/usr/local/bin/hfsfuse")
            }
        }

        fileprivate var mountArgs: [String] {
            switch self {
            case .ext2, .ext3, .ext4, .apfs, .hfsPlus: []
            case .exfat: ["-t", "exfat-fuse"]
            case .fat32: ["-t", "vfat"]
            case .udf: ["-t", "udf"]
            }
        }

        fileprivate var readOnlyArgs: [String] {
            switch self {
            case .apfs, .hfsPlus: []
            default: ["-o", "ro"]
            }
        }
    }

    public struct ToolCallError: Swift.Error, Sendable {
        public let toolURL: URL
        public let terminationStatus: Int32
        public let standardError: String?
    }

    private enum Tools {
        static let blkid = URL(filePath: "/usr/sbin/blkid")
        static let losetup = URL(filePath: "/usr/sbin/losetup")
        static let mount = URL(filePath: "/usr/bin/mount")
        static let umount = URL(filePath: "/usr/bin/umount")
    }

    public static let shared = Self.init()

    public let writableFileSystems = FileSystem.allCases.filter { $0.mkfsCommand != nil }

    public func createDiskImage(at url: URL, size: Int, fileSystem: FileSystem) throws -> URL {
        guard let mkfs = fileSystem.mkfsCommand else {
            throw Error.readOnlyFileSystem(fileSystem)
        }

        try self.createBlankFile(at: url, size: size)

        do {
            try self.runTool(url: mkfs, arguments: fileSystem.mkfsArguments + [url.path(percentEncoded: false)])

            return url
        } catch {
            try? FileManager.default.removeItem(at: url)

            throw error
        }
    }

    private func createBlankFile(at url: URL, size: Int) throws {
        let parentURL = url.deletingLastPathComponent()
        if (try? parentURL.checkResourceIsReachable()) != true {
            try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
        }

        let file = try FileDescriptor.open(
            FilePath(url.path(percentEncoded: false)),
            .writeOnly,
            options: [.create, .exclusiveCreate],
            permissions: [.ownerReadWrite, .groupRead, .otherRead]
        )

        var failed = false
        defer {
            try? file.close()
            if failed {
                try? FileManager.default.removeItem(at: url)
            }
        }

        if ftruncate(file.rawValue, off_t(size)) != 0 {
            failed = true
            throw Errno(rawValue: errno)
        }
    }

    public func mountImage(url: URL, readOnly: Bool) throws -> (mountPoint: URL, devEntry: URL) {
        let tempDir = FileManager.default.temporaryDirectory
        let mountPoint = tempDir.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let devEntry = try self.setupLoop(url: url, readOnly: readOnly)

        do {
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            try self.mountLoop(devEntry: devEntry, at: mountPoint, readOnly: readOnly)

            return (mountPoint: mountPoint, devEntry: devEntry)
        } catch {
            try? self.teardownLoop(devEntry: devEntry)

            mountPoint.withUnsafeFileSystemRepresentation {
                if let path = $0 {
                    rmdir(path)
                }
            }
            throw error
        }
    }

    private func setupLoop(url: URL, readOnly: Bool) throws -> URL {
        if self.isImageCompressed(at: url) {
            let decmpURL = try self.decompressImage(
                at: url,
                to: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            )
            defer { try? FileManager.default.removeItem(at: decmpURL) }

            return try self.setupLoop(url: decmpURL, readOnly: readOnly)
        }

        var args = ["-f", "--show"]

        if readOnly {
            args.append("-r")
        }

        args.append(url.path(percentEncoded: false))

        guard let devEntry = try self.runTool(url: Tools.losetup, arguments: args) else {
            throw CocoaError(.fileReadUnknown)
        }

        return URL(filePath: String(devEntry.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    private func teardownLoop(devEntry: URL) throws {
        try self.runTool(url: Tools.losetup, arguments: ["-d", devEntry.path(percentEncoded: false)])
    }

    private func mountLoop(
        devEntry: URL,
        at mountPoint: URL,
        fileSystem: FileSystem? = nil,
        readOnly: Bool = false
    ) throws {
        guard let fileSystem = try fileSystem ?? self.getFileSystem(at: devEntry) else {
            throw CocoaError(.fileReadUnknown)
        }

        var args = fileSystem.mountArgs
        if readOnly {
            args += fileSystem.readOnlyArgs
        }

        args += [devEntry.path(percentEncoded: false), mountPoint.path(percentEncoded: false)]

        try self.runTool(url: fileSystem.mountCommand, arguments: args)
    }

    public func unmountImage(mountPoint: URL, devEntry: URL) throws {
        try self.runTool(url: Tools.umount, arguments: ["-d", devEntry.path(percentEncoded: false)])

        guard rmdir(mountPoint.path(percentEncoded: false)) == 0 else { throw Errno(rawValue: errno) }
    }

    private func findMountPoint(devEntry: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: URL(filePath: "/proc/self/mounts"))
        defer { try? file.close() }

        guard let data = try file.readToEnd(),
              let text = String(data: data, encoding: .utf8),
              let match = text.firstMatch(of: try Regex(#"(?m)^\s*\#(devEntry.path(percentEncoded: false))\s+(\S+)\s"#)),
              let mountPoint = match[1].substring else {
            throw CocoaError(.fileNoSuchFile)
        }

        return String(mountPoint)
    }

    private func getFileSystem(at url: URL) throws -> FileSystem? {
        let path = url.path(percentEncoded: false)

        guard let response = try self.runTool(url: Tools.blkid, arguments: ["-s", "TYPE", "-o", "value", "-p", path]),
              let fileSystem = FileSystem(osName: response.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }

        return fileSystem
    }

    @discardableResult
    private func runTool(url: URL, arguments: [String]) throws -> String? {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        let stdout = stdoutPipe.fileHandleForReading
        let stderr = stderrPipe.fileHandleForReading

        defer {
            try? stdout.close()
            try? stderr.close()
        }

        process.executableURL = url
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let stdoutData = try stdout.readToEnd()
        let stderrData = try stderr.readToEnd()

        // process.waitUntilExit() hangs when mounting FUSE file-systems, but this always works
        var status: Int32 = 0
        waitpid(process.processIdentifier, &status, 0)

        if status != 0 {
            let stderrString = if let stderrData {
                String(data: stderrData, encoding: .utf8)
            } else {
                "(unknown)"
            }

            throw ToolCallError(toolURL: url, terminationStatus: (status >> 8) & 0xff, standardError: stderrString)
        }

        if let stdoutData {
            return String(data: stdoutData, encoding: .utf8)
        } else {
            return ""
        }
    }

    private func isImageCompressed(at url: URL) -> Bool {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            return try handle.read(upToCount: 3) == Data([0x62, 0x76, 0x78])
        } catch {
            return false
        }
    }

    private func decompressImage(at srcURL: URL, to destURL: URL) throws -> URL {
        let partitionHints: Set<Substring> = ["Apple_APFS", "Apple_HFS", "DOS_FAT_32", "UDF", "Windows_NTFS"]

        let srcFile = try FileHandle(forReadingFrom: srcURL)
        defer { try? srcFile.close() }

        let blockSize = 512

        try srcFile.seekToEnd()
        try srcFile.seek(toOffset: srcFile.offset() - UInt64(blockSize))
        guard let trailer = try srcFile.read(upToCount: blockSize),
              trailer.count == blockSize,
              trailer.starts(with: [0x6b, 0x6f, 0x6c, 0x79]) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let plistData = try trailer.withUnsafeBytes {
            try $0[216..<232].withMemoryRebound(to: UInt64.self) {
                try srcFile.seek(toOffset: UInt64(bigEndian: $0[0]))
                return try srcFile.read(upToCount: Int(UInt64(bigEndian: $0[1])))
            }
        }

        guard let plistData,
              let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String : Any],
              let resFork = plist["resource-fork"] as? [String : Any],
              let volumes = resFork["blkx"] as? [[String : Any]] else {
            throw CocoaError(.fileReadCorruptFile)
        }

        guard let supportedVolume = try volumes.first(where: {
            guard let match = try /.*\(\s*(\S+)\s*:\s*[0-9]+\s*\)\s*$/.firstMatch(in: $0["Name"] as? String ?? "") else {
                return false
            }

            return partitionHints.contains(match.1)
        }) else {
            print("Didn't find supported partition hint in: \(volumes.compactMap { $0["Name"] as? String })")
            throw CocoaError(.featureUnsupported)
        }

        let dstFile = try FileDescriptor.open(
            destURL.path(percentEncoded: false),
            .writeOnly,
            options: [.create, .exclusiveCreate],
            permissions: [.ownerReadWrite, .groupRead, .otherRead]
        )
        defer { try? dstFile.close() }

        do {
            try self.decompressVolume(volume: supportedVolume, srcFile: srcFile, dstFile: dstFile, blockSize: blockSize)

            return destURL
        } catch {
            try? FileManager.default.removeItem(at: destURL)
            throw error
        }
    }

    private func decompressVolume(
        volume: [String : Any],
        srcFile: FileHandle,
        dstFile: FileDescriptor,
        blockSize: Int
    ) throws {
        guard let volData = volume["Data"] as? Data,
              volData.count >= 0xcc,
              volData.starts(with: [0x6d, 0x69, 0x73, 0x68, 0x00, 0x00, 0x00, 0x01]) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        try volData.withUnsafeBytes { bytes in
            let srcOffset = UInt64(bigEndian: bytes.loadUnaligned(fromByteOffset: 0x18, as: UInt64.self))
            let chunkCount = UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: 0xc8, as: UInt32.self))

            guard bytes.count >= 0xcc + chunkCount * 0x28 else { throw CocoaError(.fileReadCorruptFile) }

            for i in 0..<Int(chunkCount) {
                let chunk = bytes[(0xcc + i * 0x28)..<(0xcc + (i + 1) * 0x28)]

                let more = try self.decompressChunk(
                    chunk: chunk,
                    srcFile: srcFile,
                    dstFile: dstFile,
                    srcOffset: srcOffset,
                    blockSize: blockSize
                )

                if !more {
                    break
                }
            }
        }
    }

    private func decompressChunk(
        chunk: UnsafeRawBufferPointer.SubSequence,
        srcFile: FileHandle,
        dstFile: FileDescriptor,
        srcOffset srcBaseOffset: UInt64,
        blockSize: Int
    ) throws -> Bool {
        let chunkType = UInt32(bigEndian: chunk.loadUnaligned(fromByteOffset: 0, as: UInt32.self))

        if chunkType == 0xffffffff {
            return false
        }

        let sectorNum = UInt64(bigEndian: chunk.loadUnaligned(fromByteOffset: 0x08, as: UInt64.self))
        let sectorCount = UInt64(bigEndian: chunk.loadUnaligned(fromByteOffset: 0x10, as: UInt64.self))
        let srcOffset = srcBaseOffset + UInt64(bigEndian: chunk.loadUnaligned(fromByteOffset: 0x18, as: UInt64.self))
        let srcLength = UInt64(bigEndian: chunk.loadUnaligned(fromByteOffset: 0x20, as: UInt64.self))
        let dstOffset = sectorNum * UInt64(blockSize)
        let dstLength = sectorCount * UInt64(blockSize)

        if chunkType == 0 || chunkType == 2 {
            let endOffset = dstOffset + dstLength

            if try dstFile.seek(offset: 0, from: .end) < endOffset {
                if ftruncate(dstFile.rawValue, off_t(endOffset)) != 0 {
                    throw Errno(rawValue: errno)
                }
            }

            return true
        }

        try srcFile.seek(toOffset: srcOffset)
        guard let srcData = try srcFile.read(upToCount: Int(srcLength)), srcData.count == srcLength else {
            throw CocoaError(.fileReadCorruptFile)
        }

        try srcData.withUnsafeBytes { bytes in
            switch chunkType {
            case 1:
                guard try dstFile.write(toAbsoluteOffset: Int64(dstOffset), bytes) == dstLength else {
                    throw CocoaError(.fileWriteUnknown)
                }
            case 0x80000007:
                try self.decompressLZFSEChunk(srcBytes: bytes, dstFile: dstFile, dstOffset: dstOffset, dstLength: dstLength)
            default:
                throw CocoaError(.featureUnsupported)
            }
        }

        return true
    }

    private func decompressLZFSEChunk(
        srcBytes: UnsafeRawBufferPointer,
        dstFile: FileDescriptor,
        dstOffset: UInt64,
        dstLength: UInt64
    ) throws {
        try withUnsafeTemporaryAllocation(of: UInt8.self, capacity: Int(dstLength)) { dst in
            let size = withUnsafeTemporaryAllocation(of: UInt8.self, capacity: lzfse_decode_scratch_size()) {
                lzfse_decode_buffer(dst.baseAddress, dst.count, srcBytes.baseAddress, srcBytes.count, $0.baseAddress)
            }

            let rawBuffer = UnsafeRawBufferPointer(UnsafeBufferPointer(rebasing: dst.prefix(Int(size))))

            guard try dstFile.write(toAbsoluteOffset: Int64(dstOffset), rawBuffer) == size else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }
}

#endif
