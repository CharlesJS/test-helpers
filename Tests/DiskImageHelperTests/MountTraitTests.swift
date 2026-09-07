//
//  MountTraitTests.swift
//  test-helpers
//
//  Created by Charles Srstka on 7/22/26.
//

@testable import DiskImageHelper
import Foundation
import Testing

#if !canImport(Darwin)
import RegexBuilder
#endif

private let fixtureURLs = Bundle.module.urls(forResourcesWithExtension: "dmg", subdirectory: "fixtures")!.map { $0 as URL }

private let withBlankImages = MountTrait(size: 1024 * 1024, fileSystems: DiskImageHelper.shared.writableFileSystems)
private let withFixtures = MountTrait<GenericDiskImageInfo>(imageInfo: fixtureURLs.compactMap { url in
    guard let fileSystem = DiskImageHelper.FileSystem(name: url.deletingPathExtension().lastPathComponent) else {
        return nil
    }

    return GenericDiskImageInfo(name: fileSystem.name, imageURL: url, fileSystem: fileSystem)
})

extension DiskImageHelperTests {
    @Suite(withBlankImages)
    struct MountTraitBlankImageTests {
        @Test(arguments: DiskImageHelper.shared.writableFileSystems.enumerated().map(\.self))
        func createsImageForCorrectFileSystem(index: Int, fileSystem: DiskImageHelper.FileSystem) {
            let image = withBlankImages.images[index]

            #expect(image.info.fileSystem == fileSystem)
            #expect(image.info.name == fileSystem.name)
        }

        @Test(arguments: withBlankImages.images)
        func mountTraitImageURLIsValid(image: MountTrait<GenericDiskImageInfo>.DiskImage) throws {
            #expect(image.imageURL.isFileURL)
            #expect(image.imageURL.pathExtension == "dmg")
            #expect(try image.imageURL.checkResourceIsReachable())
        }

        @Test(arguments: withBlankImages.images)
        func mountsImageSuccessfully(image: MountTrait<GenericDiskImageInfo>.DiskImage) throws {
            #expect(image.mountPoint.isFileURL)
            #expect(image.rootDirectory.isFileURL)
            #expect(image.devEntry.isFileURL)
            #expect(try image.mountPoint.checkResourceIsReachable())
            #expect(try image.rootDirectory.checkResourceIsReachable())
            #expect(try image.devEntry.checkResourceIsReachable())

            let resourceValues = try image.mountPoint.resourceValues(forKeys: [.isVolumeKey, .volumeURLKey])
            #expect(resourceValues.isVolume == true)
            #expect(resourceValues.volume == image.mountPoint)

            #expect(image.rootDirectory.path().hasPrefix(image.mountPoint.path()))
        }
    }

    @Suite(withFixtures)
    struct MountTraitFixtureTests {
        @Test(arguments: withFixtures.images)
        func volumeTypeIsCorrect(image: MountTrait<GenericDiskImageInfo>.DiskImage) throws {
#if canImport(Darwin)
            let typeName = try image.mountPoint.resourceValues(forKeys: [.volumeTypeNameKey]).volumeTypeName
#else
            let mounts = try String(contentsOf: URL(filePath: "/proc/self/mounts"), encoding: .utf8)
            let regex = Regex {
                Anchor.startOfLine
                ZeroOrMore(.whitespace)
                OneOrMore(.whitespace.inverted)
                OneOrMore(.whitespace)
                image.mountPoint.path(percentEncoded: false).dropLast(1) // get rid of the trailing slash
                OneOrMore(.whitespace)
            }
            try #expect(mounts.firstMatch(of: regex) != nil)

            let blkid = Process()
            let stdoutPipe = Pipe()
            let stdout = stdoutPipe.fileHandleForReading
            defer { try? stdout.close() }

            blkid.executableURL = URL(filePath: "/usr/sbin/blkid")
            blkid.arguments = ["-s", "TYPE", "-o", "value", "-p", image.devEntry.path(percentEncoded: false)]
            blkid.standardOutput = stdoutPipe

            try blkid.run()

            let output = try #require(stdout.readToEnd().flatMap { String(data: $0, encoding: .utf8) })
            let typeName = output.trimmingCharacters(in: .whitespacesAndNewlines)
#endif
            #expect(typeName == image.info.fileSystem.osName)
        }

        @Test(arguments: withFixtures.images)
        func readFileContents(image: MountTrait<GenericDiskImageInfo>.DiskImage) throws {
            let qbf = try String(contentsOf: image.rootDirectory.appending(path: "foo/qbf.txt"), encoding: .utf8)
            #expect(qbf == "The quick brown fox jumps over the lazy dog.\n")

            let lorem = try Data(contentsOf: image.rootDirectory.appending(path: "bar/loremipsum.txt"))
            #expect(lorem.count == 446)
            #expect(lorem.prefix(26) == "Lorem ipsum dolor sit amet".data(using: .utf8))
            #expect(lorem.suffix(28) == "mollit anim id est laborum.\n".data(using: .utf8))
        }
    }

    @Test
    func cleansUpBlankImages() async throws {
        actor Storage {
            var images: [(imageURL: URL, mountPoint: URL, rootDirectory: URL, devEntry: URL)] = []
            func addImage(url: URL, mountPoint: URL, rootDirectory: URL, devEntry: URL) {
                self.images.append((imageURL: url, mountPoint: mountPoint, rootDirectory: rootDirectory, devEntry: devEntry))
            }
        }

        let imageStorage = Storage()

        try await withBlankImages.provideScope(for: .current!, testCase: nil) {
            for eachImage in withBlankImages.images {
                await imageStorage.addImage(
                    url: eachImage.imageURL,
                    mountPoint: eachImage.mountPoint,
                    rootDirectory: eachImage.rootDirectory,
                    devEntry: eachImage.devEntry
                )

                try #expect(eachImage.imageURL.checkResourceIsReachable())
                try #expect(eachImage.mountPoint.checkResourceIsReachable())
                try #expect(eachImage.rootDirectory.checkResourceIsReachable())
                try #expect(eachImage.devEntry.checkResourceIsReachable())

                try #expect(eachImage.mountPoint.resourceValues(forKeys: [.isVolumeKey]).isVolume == true)
            }
        }

#if !canImport(Darwin)
        let mounts = try String(contentsOf: URL(filePath: "/proc/self/mounts"), encoding: .utf8)
#endif

        for eachImage in await imageStorage.images {
            let imageURLError = #expect(throws: CocoaError.self) { try eachImage.imageURL.checkResourceIsReachable() }
            let mountPointError = #expect(throws: CocoaError.self) { try eachImage.mountPoint.checkResourceIsReachable() }
            let rootDirError = #expect(throws: CocoaError.self) { try eachImage.rootDirectory.checkResourceIsReachable() }

            #expect(imageURLError?.code == .fileReadNoSuchFile)
            #expect(mountPointError?.code == .fileReadNoSuchFile)
            #expect(rootDirError?.code == .fileReadNoSuchFile)

#if canImport(Darwin)
            let devError = #expect(throws: CocoaError.self) {
                try eachImage.devEntry.checkResourceIsReachable()
            }

            #expect(devError?.code == .fileReadNoSuchFile)
#else
            #expect(!mounts.contains(eachImage.mountPoint.path(percentEncoded: false).dropLast(1)))
            #expect(!mounts.contains(eachImage.devEntry.path(percentEncoded: false)))
#endif
        }
    }
}
