//
//  MountTrait.swift
//  test-helpers
//
//  Created by Charles Srstka on 7/22/26.
//

import Foundation
import Testing

#if canImport(SystemPackage)
import SystemPackage
#else
import System
#endif

public protocol TopLevelDecoder {
    func decode<T>(_ type: T.Type, from: Data) throws -> T where T : Decodable
}

extension JSONDecoder: TopLevelDecoder {}
extension PropertyListDecoder: TopLevelDecoder {}

@available(macOS 10.15.4, *)
public protocol DiskImageInfo: Codable, Sendable {
    var name: String { get }
    var imageURL: URL { get }
    var fileSystem: DiskImageHelper.FileSystem { get }

    static func decode(data: Data, decoder: some TopLevelDecoder) throws -> [Self]
}

@available(macOS 10.15.4, *)
public struct GenericDiskImageInfo: DiskImageInfo {
    public let name: String
    public let imageURL: URL
    public let fileSystem: DiskImageHelper.FileSystem
    public init(name: String, imageURL: URL, fileSystem: DiskImageHelper.FileSystem) {
        self.name = name
        self.imageURL = imageURL
        self.fileSystem = fileSystem
    }

    public static func decode(data: Data, decoder: some TopLevelDecoder) throws -> [Self] {
        try decoder.decode([Self].self, from: data)
    }
}

@TaskLocal private var _mountedImages: [UUID : (mountPoint: URL, rootDirectory: URL, devEntry: URL)] = [:]

@available(macOS 10.15.4, *)
public struct MountTrait<Info: DiskImageInfo>: SuiteTrait, TestScoping {
    public struct DiskImage: CustomTestStringConvertible, Sendable {
        public var imageURL: URL { self.info.imageURL }

        public var mountPoint: URL {
            guard let mountedImage = _mountedImages[self.uuid] else {
                preconditionFailure("This property must only be called from inside the scope of a test")
            }

            return mountedImage.mountPoint
        }

        public var rootDirectory: URL {
            guard let mountedImage = _mountedImages[self.uuid] else {
                preconditionFailure("This property must only be called from inside the scope of a test")
            }

            return mountedImage.rootDirectory
        }

        public var devEntry: URL {
            guard let mountedImage = _mountedImages[self.uuid] else {
                preconditionFailure("This property must only be called from inside the scope of a test")
            }

            return mountedImage.devEntry
        }

        public let info: Info

        public var testDescription: String { self.imageURL.lastPathComponent }

        fileprivate let uuid: UUID
        fileprivate let createInfo: (size: Int, fileSystem: DiskImageHelper.FileSystem)?
    }

    public let images: [DiskImage]

    public init(imageInfo: some Sequence<Info>) {
        self.images = imageInfo.map { info in
            DiskImage(info: info, uuid: UUID(), createInfo: nil)
        }
    }

    public func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing f: @Sendable () async throws -> Void
    ) async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let dmgHelper = DiskImageHelper.shared

        var createdImages: [URL] = []
        var mountedImages: [UUID : (mountPoint: URL, rootDirectory: URL, devEntry: URL)] = [:]
        createdImages.reserveCapacity(self.images.count)
        mountedImages.reserveCapacity(self.images.count)

        defer {
            for (mountPoint, _, devEntry) in mountedImages.values {
                do {
                    try dmgHelper.unmountImage(mountPoint: mountPoint, devEntry: devEntry)
                } catch {
                    print("Error unmounting \(devEntry.path): \(error)")
                }
            }

            for eachImage in createdImages {
                try? FileManager.default.removeItem(at: eachImage)
            }
        }

        for eachImage in self.images {
            if let (size: size, fileSystem: fileSystem) = eachImage.createInfo {
                let dmgURL = try dmgHelper.createDiskImage(at: eachImage.imageURL, size: size, fileSystem: fileSystem)
                createdImages.append(dmgURL)
            }

            try mountedImages[eachImage.uuid] = dmgHelper.mountImage(url: eachImage.imageURL, readOnly: true)
        }

        try await $_mountedImages.withValue(mountedImages) {
            try await f()
        }
    }
}

@available(macOS 10.15.4, *)
extension MountTrait where Info == GenericDiskImageInfo {
    public init(size: Int, fileSystems: [DiskImageHelper.FileSystem]) {
        self.images = fileSystems.map { fileSystem in
            let uuid = UUID()
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(uuid.uuidString)
            let url = tempDir.appendingPathComponent("\(fileSystem.name).dmg")

            return DiskImage(
                info: GenericDiskImageInfo(name: fileSystem.name, imageURL: url, fileSystem: fileSystem),
                uuid: UUID(),
                createInfo: (size: size, fileSystem: fileSystem)
            )
        }
    }
}

@available(macOS 10.15.4, *)
private struct InfoWrapper<Info: DiskImageInfo>: Decodable {
    let imageInfo: Info?

    init(from decoder: any Decoder) throws {
        do {
            self.imageInfo = try Info(from: decoder)
        } catch DecodingError.dataCorrupted(let context) {
            if context.codingPath.last?.stringValue == "fileSystem" {
                self.imageInfo = nil
            } else {
                throw DecodingError.dataCorrupted(context)
            }
        }
    }
}

@available(macOS 10.15.4, *)
extension DiskImageInfo {
    public static func decode(data: Data, decoder: some TopLevelDecoder) throws -> [Self] {
        try decoder.decode([InfoWrapper].self, from: data).compactMap(\.imageInfo)
    }
}
