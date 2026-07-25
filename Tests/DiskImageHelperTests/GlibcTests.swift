////
////  GlibcTests.swift
////  test-helpers
////
////  Created by Charles Srstka on 7/22/26.
////
//
//#if canImport(Glibc)
//
//@testable import DiskImageHelper
//import Foundation
//import Testing
//
//@Suite struct GlibcTests {
//    @Test func createDiskImageCreatesFile() async throws {
//        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
//        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
//        defer { try? FileManager.default.removeItem(at: tempDir) }
//
//        let targetURL = tempDir.appendingPathComponent("test-image")
//        let resultURL = try DiskImageHelper.shared.createDiskImage(at: targetURL, size: 1024 * 1024, fileSystem: .ext4)
//
//        #expect(resultURL.isFileURL)
//        #expect((try? resultURL.checkResourceIsReachable()) == true)
//    }
//
//    @Test func createDiskImageCreatesCorrectSize() async throws {
//        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
//        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
//        defer { try? FileManager.default.removeItem(at: tempDir) }
//
//        let targetURL = tempDir.appendingPathComponent("size-test")
//        let expectedSize = 5 * 1024 * 1024
//        let resultURL = try DiskImageHelper.shared.createDiskImage(at: targetURL, size: expectedSize, fileSystem: .ext4)
//
//        let attributes = try FileManager.default.attributesOfItem(atPath: resultURL.path())
//        let fileSize = attributes[.size] as? Int ?? 0
//        #expect(fileSize >= expectedSize)
//    }
//
//    @Test func createDiskImageSupportsAllFileSystems() async throws {
//        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
//        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
//        defer { try? FileManager.default.removeItem(at: tempDir) }
//
//        let dmgHelper = DiskImageHelper.shared
//
//        for fileSystem in DiskImageHelper.FileSystem.allCases {
//            let targetURL = tempDir.appendingPathComponent("\(fileSystem.name)-test")
//            let resultURL = try dmgHelper.createDiskImage(at: targetURL, size: 1024 * 1024, fileSystem: fileSystem)
//            #expect((try? resultURL.checkResourceIsReachable()) == true)
//        }
//    }
//
//    @Test func createDiskImageCreatesParentDirectory() async throws {
//        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
//        let nestedDir = tempDir.appendingPathComponent("nested").appendingPathComponent("deep")
//        defer { try? FileManager.default.removeItem(at: tempDir) }
//
//        let targetURL = nestedDir.appendingPathComponent("parent-test")
//        let resultURL = try DiskImageHelper.shared.createDiskImage(at: targetURL, size: 1024 * 1024, fileSystem: .ext4)
//
//        #expect((try? resultURL.checkResourceIsReachable()) == true)
//        #expect((try? nestedDir.checkResourceIsReachable()) == true)
//    }
//
//    // MARK: - mountImage Tests
//
//    @Test func mountImageReturnsValidMountPoint() async throws {
//        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
//        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
//        defer { try? FileManager.default.removeItem(at: tempDir) }
//
//        let targetURL = tempDir.appendingPathComponent("mount-test")
//        let imageURL = try DiskImageHelper.shared.createDiskImage(at: targetURL, size: 1024 * 1024, fileSystem: .ext4)
//
//        let (mountPoint, devEntry) = try DiskImageHelper.shared.mountImage(url: imageURL, readOnly: false)
//        defer { try? DiskImageHelper.shared.unmountImage(devEntry: devEntry) }
//
//        #expect(mountPoint.isFileURL)
//        #expect((try? mountPoint.checkResourceIsReachable()) == true)
//        #expect(!devEntry.isEmpty)
//
//    }
//
//    @Test func mountImageReadOnlyCreatesReadOnlyMount() async throws {
//        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
//        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
//        defer { try? FileManager.default.removeItem(at: tempDir) }
//
//        let targetURL = tempDir.appendingPathComponent("readonly-test")
//        let imageURL = try DiskImageHelper.shared.createDiskImage(at: targetURL, size: 1024 * 1024, fileSystem: .ext4)
//
//        let (mountPoint, devEntry) = try DiskImageHelper.shared.mountImage(url: imageURL, readOnly: true)
//        defer { try? DiskImageHelper.shared.unmountImage(devEntry: devEntry) }
//
//        #expect(mountPoint.isFileURL)
//        #expect((try? mountPoint.checkResourceIsReachable()) == true)
//    }
//
//    @Test func mountImageDevEntryFormat() async throws {
//        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
//        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
//        defer { try? FileManager.default.removeItem(at: tempDir) }
//
//        let targetURL = tempDir.appendingPathComponent("deventry-test")
//        let imageURL = try DiskImageHelper.shared.createDiskImage(at: targetURL, size: 1024 * 1024, fileSystem: .ext4)
//
//        let (_, devEntry) = try DiskImageHelper.shared.mountImage(url: imageURL, readOnly: false)
//        defer { try? DiskImageHelper.shared.unmountImage(devEntry: devEntry) }
//
//        #expect(devEntry.hasPrefix("/dev/loop"))
//    }
//
//    // MARK: - unmountImage Tests
//
//    @Test func unmountImageSuccessfullyDetaches() async throws {
//        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
//        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
//        defer { try? FileManager.default.removeItem(at: tempDir) }
//
//        let targetURL = tempDir.appendingPathComponent("unmount-test")
//        let imageURL = try DiskImageHelper.shared.createDiskImage(at: targetURL, size: 1024 * 1024, fileSystem: .ext4)
//
//        let (_, devEntry) = try DiskImageHelper.shared.mountImage(url: imageURL, readOnly: false)
//
//        try DiskImageHelper.shared.unmountImage(devEntry: devEntry)
//    }
//
//    // MARK: - Integration Tests
//
//    @Test func fullMountUnmountCycle() async throws {
//        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
//        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
//        defer { try? FileManager.default.removeItem(at: tempDir) }
//
//        let targetURL = tempDir.appendingPathComponent("integration-test")
//        let imageURL = try DiskImageHelper.shared.createDiskImage(at: targetURL, size: 1024 * 1024, fileSystem: .ext4)
//
//        let (mountPoint, devEntry) = try DiskImageHelper.shared.mountImage(url: imageURL, readOnly: false)
//        #expect((try? mountPoint.checkResourceIsReachable()) == true)
//
//        try DiskImageHelper.shared.unmountImage(devEntry: devEntry)
//    }
//
//    @Test func multipleMountUnmountCycles() async throws {
//        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
//        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
//        defer { try? FileManager.default.removeItem(at: tempDir) }
//
//        for fileSystem in DiskImageHelper.FileSystem.allCases {
//            let targetURL = tempDir.appendingPathComponent("\(fileSystem.name)-cycle")
//            let imageURL = try DiskImageHelper.shared.createDiskImage(at: targetURL, size: 1024 * 1024, fileSystem: fileSystem)
//
//            let (_, devEntry) = try DiskImageHelper.shared.mountImage(url: imageURL, readOnly: false)
//            try DiskImageHelper.shared.unmountImage(devEntry: devEntry)
//        }
//    }
//
//    private func sha256(at url: URL) throws -> String {
//        let process = Process()
//        let stdout = Pipe()
//        let stderr = Pipe()
//        let toolURL = URL(filePath: "/usr/bin/sha256sum")
//
//        process.executableURL = toolURL
//        process.arguments = [url.path()]
//        process.standardOutput = stdout
//        process.standardError = stderr
//
//        try process.run()
//        process.waitUntilExit()
//
//        guard let rawOutput = try stdout.fileHandleForReading.readToEnd(),
//              let output = String(data: rawOutput, encoding: .utf8) else {
//            let raw = try stderr.fileHandleForReading.readToEnd()
//            let err = String(data: raw, encoding: .utf8) ?? "unknown"
//
//            throw ToolCallError(toolURL: toolURL, terminationStatus: process.terminationStatus, standardError: err)
//        }
//
//        return output.trimmingCharacters(in: .whitespacesAndNewlines)
//    }
//}
//
//#endif
