//
//  DiskImageHelperTests.swift
//  test-helpers
//
//  Created by Charles Srstka on 7/22/26.
//

@testable import DiskImageHelper
import Foundation
import Testing

@Suite(.serialized)
struct DiskImageHelperTests {
#if canImport(Darwin)
    private static let defaultFileSystem = DiskImageHelper.FileSystem.apfs
#else
    private static let defaultFileSystem = DiskImageHelper.FileSystem.ext4
#endif

    @Test func createDiskImageReturnsValidURL() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let targetURL = tempDir.appendingPathComponent("test-image")
        let resultURL = try DiskImageHelper.shared.createDiskImage(
            at: targetURL,
            size: Self.defaultFileSystem.minimumSize,
            fileSystem: Self.defaultFileSystem
        )

        #expect(resultURL.isFileURL)
        #expect((try? resultURL.checkResourceIsReachable()) == true)
    }

    @Test func createDiskImageCreatesCorrectSize() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let targetURL = tempDir.appendingPathComponent("size-test")
        let expectedSize = 5 * Self.defaultFileSystem.minimumSize
        let resultURL = try DiskImageHelper.shared.createDiskImage(
            at: targetURL,
            size: expectedSize,
            fileSystem: Self.defaultFileSystem
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: resultURL.path)
        let fileSize = attributes[.size] as? Int ?? 0
        #expect(fileSize >= expectedSize)
    }

    @Test(arguments: DiskImageHelper.shared.writableFileSystems)
    func createDiskImageSupportsAllFileSystems(fileSystem: DiskImageHelper.FileSystem) async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let targetURL = tempDir.appendingPathComponent("\(fileSystem.name)-test")
        let resultURL = try DiskImageHelper.shared.createDiskImage(
            at: targetURL,
            size: fileSystem.minimumSize,
            fileSystem: fileSystem
        )
        #expect((try? resultURL.checkResourceIsReachable()) == true)

        let (mountPoint, rootDir, devEntry) = try DiskImageHelper.shared.mountImage(url: resultURL, readOnly: true)
        defer { try? DiskImageHelper.shared.unmountImage(mountPoint: mountPoint, devEntry: devEntry) }
#if canImport(Darwin)
        #expect(try rootDir.resourceValues(forKeys: [.volumeTypeNameKey]).volumeTypeName == fileSystem.osName)
#else
        let blkid = Process()
        let stdoutPipe = Pipe()
        let stdout = stdoutPipe.fileHandleForReading
        defer { try? stdout.close() }

        blkid.executableURL = URL(filePath: "/usr/sbin/blkid")
        blkid.arguments = ["-s", "TYPE", "-o", "value", "-p", devEntry.path(percentEncoded: false)]
        blkid.standardOutput = stdoutPipe

        try blkid.run()

        let output = try #require(stdout.readToEnd().flatMap { String(data: $0, encoding: .utf8) })
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == fileSystem.osName)
#endif
    }

    // MARK: - mountImage Tests

    @Test func mountImageReturnsValidMountPoint() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let targetURL = tempDir.appendingPathComponent("mount-test")
        let imageURL = try DiskImageHelper.shared.createDiskImage(
            at: targetURL,
            size: Self.defaultFileSystem.minimumSize,
            fileSystem: Self.defaultFileSystem
        )

        let (mountPoint, rootDir, devEntry) = try DiskImageHelper.shared.mountImage(url: imageURL, readOnly: false)
        defer { try? DiskImageHelper.shared.unmountImage(mountPoint: mountPoint, devEntry: devEntry) }

        #expect(mountPoint.isFileURL)
        #expect((try? mountPoint.checkResourceIsReachable()) == true)
        #expect(rootDir.isFileURL)
        #expect((try? rootDir.checkResourceIsReachable()) == true)
        #expect(devEntry.isFileURL)
        #expect((try? devEntry.checkResourceIsReachable()) == true)

        let testfile = rootDir.appendingPathComponent("write-test-\(UUID().uuidString)")
        try "Writability Test".write(to: testfile, atomically: true, encoding: .utf8)
        #expect((try? testfile.checkResourceIsReachable()) == true)
    }

    @Test func mountImageReadOnlyCreatesReadOnlyMount() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let targetURL = tempDir.appendingPathComponent("readonly-test")
        let imageURL = try DiskImageHelper.shared.createDiskImage(
            at: targetURL,
            size: Self.defaultFileSystem.minimumSize,
            fileSystem: Self.defaultFileSystem
        )

        let (mountPoint, rootDir, devEntry) = try DiskImageHelper.shared.mountImage(url: imageURL, readOnly: true)
        defer { try? DiskImageHelper.shared.unmountImage(mountPoint: mountPoint, devEntry: devEntry) }

        #expect(mountPoint.isFileURL)
        #expect((try? mountPoint.checkResourceIsReachable()) == true)
        #expect(rootDir.isFileURL)
        #expect((try? rootDir.checkResourceIsReachable()) == true)
        #expect(devEntry.isFileURL)
        #expect((try? devEntry.checkResourceIsReachable()) == true)

        let testfile = rootDir.appendingPathComponent("write-test-\(UUID().uuidString)")
        #expect(
            #expect(throws: CocoaError.self) {
                try "Writability Test".write(to: testfile, atomically: true, encoding: .utf8)
            }?.code == .fileWriteVolumeReadOnly
        )
        #expect((try? testfile.checkResourceIsReachable()) != true)
    }

    @Test func mountImageDevEntryFormat() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let targetURL = tempDir.appendingPathComponent("deventry-test")
        let imageURL = try DiskImageHelper.shared.createDiskImage(
            at: targetURL,
            size: Self.defaultFileSystem.minimumSize,
            fileSystem: Self.defaultFileSystem
        )

        let (mountPoint, _, devEntry) = try DiskImageHelper.shared.mountImage(url: imageURL, readOnly: false)
        defer { try? DiskImageHelper.shared.unmountImage(mountPoint: mountPoint, devEntry: devEntry) }

        #expect(devEntry.path(percentEncoded: false).hasPrefix("/dev/"))
    }

    // MARK: - unmountImage Tests

    @Test func unmountImageSuccessfullyDetaches() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let targetURL = tempDir.appendingPathComponent("unmount-test")
        let imageURL = try DiskImageHelper.shared.createDiskImage(
            at: targetURL,
            size: Self.defaultFileSystem.minimumSize,
            fileSystem: Self.defaultFileSystem
        )

        let mounts = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil) ?? []
        let (mountPoint, rootDir, devEntry) = try DiskImageHelper.shared.mountImage(url: imageURL, readOnly: false)
        #expect((try? mountPoint.checkResourceIsReachable()) == true)
        #expect((try? rootDir.checkResourceIsReachable()) == true)
        #expect((try? devEntry.checkResourceIsReachable()) == true)
        #expect(FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil)?.count == mounts.count + 1)

        try DiskImageHelper.shared.unmountImage(mountPoint: mountPoint, devEntry: devEntry)

        #expect((try? mountPoint.checkResourceIsReachable()) != true)
        #expect((try? rootDir.checkResourceIsReachable()) != true)
#if canImport(Darwin)
        #expect((try? devEntry.checkResourceIsReachable()) != true)
#endif
        #expect(FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil) == mounts)
    }

    // MARK: - Integration Tests

    @Test func fullMountUnmountCycle() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let targetURL = tempDir.appendingPathComponent("integration-test")
        let imageURL = try DiskImageHelper.shared.createDiskImage(
            at: targetURL,
            size: Self.defaultFileSystem.minimumSize,
            fileSystem: Self.defaultFileSystem
        )

        let (mountPoint, rootDir, devEntry) = try DiskImageHelper.shared.mountImage(url: imageURL, readOnly: false)
        #expect((try? mountPoint.checkResourceIsReachable()) == true)
        #expect((try? rootDir.checkResourceIsReachable()) == true)

        try DiskImageHelper.shared.unmountImage(mountPoint: mountPoint, devEntry: devEntry)
        #expect((try? mountPoint.checkResourceIsReachable()) != true)
        #expect((try? rootDir.checkResourceIsReachable()) != true)
    }

    @Test func multipleMountUnmountCycles() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for fileSystem in DiskImageHelper.shared.writableFileSystems {
            let targetURL = tempDir.appendingPathComponent("\(fileSystem.name)-cycle")
            let imageURL = try DiskImageHelper.shared.createDiskImage(
                at: targetURL,
                size: fileSystem.minimumSize,
                fileSystem: fileSystem
            )

            let (mountPoint, _, devEntry) = try DiskImageHelper.shared.mountImage(url: imageURL, readOnly: false)
            try DiskImageHelper.shared.unmountImage(mountPoint: mountPoint, devEntry: devEntry)
        }
    }
}
