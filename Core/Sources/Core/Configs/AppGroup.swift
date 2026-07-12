import Foundation

public enum AppGroup {
    public static var azooKeyMacIdentifier: String {
        if let override = ProcessInfo.processInfo.environment[
            "GRIMODEX_APP_GROUP_IDENTIFIER"
        ], !override.isEmpty {
            return override
        }
        if let configured = Bundle.main.object(
            forInfoDictionaryKey: "GrimodexAppGroupIdentifier"
        ) as? String,
           !configured.isEmpty {
            return configured
        }
        #if os(macOS)
        if let executableURL = Bundle.main.executableURL {
            let appInfoURL = executableURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Info.plist")
            if let data = try? Data(contentsOf: appInfoURL),
               let object = try? PropertyListSerialization.propertyList(
                   from: data,
                   options: [],
                   format: nil
               ),
               let info = object as? [String: Any],
               let configured = info["GrimodexAppGroupIdentifier"] as? String,
               !configured.isEmpty {
                return configured
            }
        }
        #endif
        return "group.com.miyakey.grimodex.inputmethod"
    }

    #if os(macOS)
    public static func containerURL(fileManager: FileManager = .default) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: Self.azooKeyMacIdentifier)
    }

    public static func applicationSupportDirectoryURL(fileManager: FileManager = .default) -> URL {
        if let containerURL = Self.containerURL(fileManager: fileManager) {
            return containerURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("azooKey", isDirectory: true)
        }

        if #available(macOS 13, *) {
            return URL.applicationSupportDirectory
                .appending(path: "azooKey", directoryHint: .isDirectory)
        }
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("azooKey", isDirectory: true)
    }

    public static func memoryDirectoryURL(fileManager: FileManager = .default) -> URL {
        Self.applicationSupportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent("memory", isDirectory: true)
    }
    #endif
}
