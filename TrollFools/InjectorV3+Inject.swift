//
//  InjectorV3+Inject.swift
//  TrollFools
//
//  Created by 82Flex on 2025/1/10.
//

import CocoaLumberjackSwift
import Foundation

extension InjectorV3 {
    enum Strategy: String, CaseIterable {
        case lexicographic
        case fast
        case preorder
        case postorder

        var localizedDescription: String {
            switch self {
            case .lexicographic:
                return NSLocalizedString("Lexicographic", comment: "")
            case .fast:
                return NSLocalizedString("Fast", comment: "")
            case .preorder:
                return NSLocalizedString("Pre-order", comment: "")
            case .postorder:
                return NSLocalizedString("Post-order", comment: "")
            }
        }
    }

    // MARK: - Instance Methods

    func inject(_ assetURLs: [URL], shouldPersist: Bool) throws {
        let preparedAssetURLs = try preprocessAssets(assetURLs)

        precondition(!preparedAssetURLs.isEmpty, "No asset to inject.")
        terminateApp()

        try injectBundles(
            preparedAssetURLs.filter { $0.pathExtension.lowercased() == "bundle" }
        )

        try injectDylibsAndFrameworks(
            preparedAssetURLs.filter {
                let ext = $0.pathExtension.lowercased()
                return ext == "dylib" || ext == "framework"
            }
        )

        if shouldPersist {
            try persist(preparedAssetURLs)
        }
    }

    // MARK: - Private Methods

    fileprivate func injectBundles(_ assetURLs: [URL]) throws {
        guard !assetURLs.isEmpty else { return }

        for assetURL in assetURLs {
            let targetURL = bundleURL.appendingPathComponent(assetURL.lastPathComponent)
            try cmdCopy(from: assetURL, to: targetURL, clone: true, overwrite: true)
            try cmdChangeOwnerToInstalld(targetURL, recursively: true)
        }
    }

    fileprivate func injectDylibsAndFrameworks(_ assetURLs: [URL]) throws {
        guard !assetURLs.isEmpty else { return }

        // Bypass CoreTrust cho bản nguồn
        try assetURLs.forEach {
            try applyCoreTrustBypass($0)
        }

        // Mach-O đích cố định: UnityFramework
        let targetMachO = frameworksDirectoryURL
            .appendingPathComponent("UnityFramework.framework")
            .appendingPathComponent("UnityFramework")

        guard FileManager.default.isReadableFile(atPath: targetMachO.path) else {
            DDLogError("UnityFramework Mach-O not found at \(targetMachO.path)", ddlog: logger)
            throw Error.generic(NSLocalizedString(
                "UnityFramework not found in /Frameworks.",
                comment: ""
            ))
        }

        DDLogInfo("Using fixed target Mach-O: \(targetMachO.path)", ddlog: logger)

        let resourceURLs: [URL] = assetURLs

        try makeAlternate(targetMachO)
        do {
            // Copy vào /Frameworks
            try copyfiles(resourceURLs)

            // Chèn load command
            for assetURL in assetURLs {
                
                // XỬ LÝ RIÊNG anogs.framework
                if assetURL.lastPathComponent == "anogs.framework" {

                    DDLogInfo("Injecting anogs.framework with extra Mach-O 'anogs '", ddlog: logger)

                    // LC_LOAD_DYLIB mới (CÓ DẤU CÁCH)
                    let loadName = "@rpath/anogs.framework/anogs "   // <-- CÓ SPACE

                    // Đảm bảo có rpath đúng
                    try cmdInsertLoadCommandRuntimePath(targetMachO, name: "@executable_path/Frameworks")

                    // Thêm LC_LOAD_DYLIB
                    try cmdInsertLoadCommandDylib(targetMachO, name: loadName, weak: useWeakReference)
                    try standardizeLoadCommandDylib(targetMachO, to: loadName)

                    // CoreTrust bypass cho file Mach-O extra "anogs "
                    let extraMachO = frameworksDirectoryURL
                        .appendingPathComponent("anogs.framework")
                        .appendingPathComponent("anogs ") // <-- CÓ SPACE

                    if FileManager.default.isReadableFile(atPath: extraMachO.path) {
                        DDLogInfo("CoreTrust bypass extra Mach-O: \(extraMachO.path)", ddlog: logger)
                        try cmdCoreTrustBypass(extraMachO, teamID: teamID)
                        try cmdChangeOwnerToInstalld(extraMachO.deletingLastPathComponent(), recursively: true)
                    } else {
                        DDLogWarn("Extra Mach-O 'anogs ' not found at \(extraMachO.path)", ddlog: logger)
                    }

                    continue
                }

                // Asset khác: chèn LC như thường
                try insertLoadCommandOfAsset(assetURL, to: targetMachO)
            }

            // Cuối cùng bypass lại Mach-O chính
            try applyCoreTrustBypass(targetMachO)

        } catch {
            try? restoreAlternate(targetMachO)
            try? batchRemove(resourceURLs)
            throw error
        }
    }

    // MARK: - CoreTrust

    fileprivate func applyCoreTrustBypass(_ target: URL) throws {
        let isFramework = checkIsBundle(target)
        let machO = isFramework ? try locateExecutableInBundle(target) : target
        try cmdCoreTrustBypass(machO, teamID: teamID)
        try cmdChangeOwnerToInstalld(target, recursively: isFramework)
    }

    // MARK: - Load Commands

    func loadCommandNameOfAsset(_ assetURL: URL) throws -> String {
        var name = "@rpath/"

        if checkIsBundle(assetURL) {
            let machO = try locateExecutableInBundle(assetURL)
            name += machO.pathComponents.suffix(2).joined(separator: "/")
        } else {
            name += assetURL.lastPathComponent
        }

        return name
    }

    fileprivate func insertLoadCommandOfAsset(_ assetURL: URL, to target: URL) throws {
        let name = try loadCommandNameOfAsset(assetURL)
        try cmdInsertLoadCommandRuntimePath(target, name: "@executable_path/Frameworks")
        try cmdInsertLoadCommandDylib(target, name: name, weak: useWeakReference)
        try standardizeLoadCommandDylib(target, to: name)
    }

    fileprivate func standardizeLoadCommandDylib(_ target: URL, to name: String) throws {
        let itemName = String(name.dropFirst(7)) // drop "@rpath/"
        let dylibs = try loadedDylibsOfMachO(target)

        for dylib in dylibs {
            if dylib.hasSuffix("/" + itemName) {
                try cmdChangeLoadCommandDylib(target, from: dylib, to: name)
            }
        }
    }

    // MARK: - Copy / Remove

    fileprivate func copyfiles(_ assetURLs: [URL]) throws {
        let targetURLs = assetURLs.map {
            frameworksDirectoryURL.appendingPathComponent($0.lastPathComponent)
        }

        for (assetURL, targetURL) in zip(assetURLs, targetURLs) {
            try cmdCopy(from: assetURL, to: targetURL, clone: true, overwrite: true)
            try cmdChangeOwnerToInstalld(targetURL, recursively: checkIsDirectory(assetURL))
        }
    }

    fileprivate func batchRemove(_ assetURLs: [URL]) throws {
        try assetURLs.forEach {
            try cmdRemove($0, recursively: checkIsDirectory($0))
        }
    }

    // MARK: - Path Finder

    fileprivate func locateAvailableMachO() throws -> URL? {
        try frameworkMachOsInBundle(bundleURL)
            .first { try !isProtectedMachO($0) }
    }

    fileprivate static func findResource(_ name: String, fileExtension: String) -> URL {
        if let url = Bundle.main.url(forResource: name, withExtension: fileExtension) {
            return url
        }
        if let firstArg = ProcessInfo.processInfo.arguments.first {
            let execURL = URL(fileURLWithPath: firstArg)
                .deletingLastPathComponent()
                .appendingPathComponent(name)
                .appendingPathExtension(fileExtension)
            if FileManager.default.isReadableFile(atPath: execURL.path) {
                return execURL
            }
        }
        fatalError("Unable to locate resource \(name)")
    }
}
