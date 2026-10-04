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

        let image = try DiskImageHelper.shared.mountImage(url: resultURL, readOnly: true)
        defer { try? DiskImageHelper.shared.unmountImage(image) }
#if canImport(Darwin)
        #expect(try image.rootDirectory.resourceValues(forKeys: [.volumeTypeNameKey]).volumeTypeName == fileSystem.osName)
#else
        let blkid = Process()
        let stdoutPipe = Pipe()
        let stdout = stdoutPipe.fileHandleForReading
        defer { try? stdout.close() }

        blkid.executableURL = URL(filePath: "/usr/bin/sudo")
        blkid.arguments = ["/usr/sbin/blkid", "-s", "TYPE", "-o", "value", "-p", devEntry.path(percentEncoded: false)]
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

        let image = try DiskImageHelper.shared.mountImage(url: imageURL, readOnly: false)
        defer { try? DiskImageHelper.shared.unmountImage(image) }

        #expect(image.mountPoint.isFileURL)
        #expect((try? image.mountPoint.checkResourceIsReachable()) == true)
        #expect(image.rootDirectory.isFileURL)
        #expect((try? image.rootDirectory.checkResourceIsReachable()) == true)
        #expect(image.devEntry.isFileURL)
        #expect((try? image.devEntry.checkResourceIsReachable()) == true)

        let sudo = Process()
        sudo.executableURL = URL(filePath: "/usr/bin/sudo")
        sudo.arguments = ["chown", "-R", "\(getuid())", image.rootDirectory.path(percentEncoded: false)]
        try sudo.run()
        sudo.waitUntilExit()

        let testfile = image.rootDirectory.appendingPathComponent("write-test-\(UUID().uuidString)")
        try "Writability Test".write(to: testfile, atomically: true, encoding: .utf8)
        #expect((try? String(contentsOf: testfile, encoding: .utf8)) == "Writability Test")
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

        let image = try DiskImageHelper.shared.mountImage(url: imageURL, readOnly: true)
        defer { try? DiskImageHelper.shared.unmountImage(image) }

        #expect(image.mountPoint.isFileURL)
        #expect((try? image.mountPoint.checkResourceIsReachable()) == true)
        #expect(image.rootDirectory.isFileURL)
        #expect((try? image.rootDirectory.checkResourceIsReachable()) == true)
        #expect(image.devEntry.isFileURL)
        #expect((try? image.devEntry.checkResourceIsReachable()) == true)

        let testfile = image.rootDirectory.appendingPathComponent("write-test-\(UUID().uuidString)")
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

        let image = try DiskImageHelper.shared.mountImage(url: imageURL, readOnly: false)
        defer { try? DiskImageHelper.shared.unmountImage(image) }

        #expect(image.devEntry.path(percentEncoded: false).hasPrefix("/dev/"))
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
        let image = try DiskImageHelper.shared.mountImage(url: imageURL, readOnly: false)
        #expect((try? image.mountPoint.checkResourceIsReachable()) == true)
        #expect((try? image.rootDirectory.checkResourceIsReachable()) == true)
        #expect((try? image.devEntry.checkResourceIsReachable()) == true)
        #expect(FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil)?.count == mounts.count + 1)

        try DiskImageHelper.shared.unmountImage(image)

        #expect((try? image.mountPoint.checkResourceIsReachable()) != true)
        #expect((try? image.rootDirectory.checkResourceIsReachable()) != true)
#if canImport(Darwin)
        #expect((try? image.devEntry.checkResourceIsReachable()) != true)
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

        let image = try DiskImageHelper.shared.mountImage(url: imageURL, readOnly: false)
        #expect((try? image.mountPoint.checkResourceIsReachable()) == true)
        #expect((try? image.rootDirectory.checkResourceIsReachable()) == true)

        try DiskImageHelper.shared.unmountImage(image)
        #expect((try? image.mountPoint.checkResourceIsReachable()) != true)
        #expect((try? image.rootDirectory.checkResourceIsReachable()) != true)
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

            let image = try DiskImageHelper.shared.mountImage(url: imageURL, readOnly: false)
            try DiskImageHelper.shared.unmountImage(image)
        }
    }
}
