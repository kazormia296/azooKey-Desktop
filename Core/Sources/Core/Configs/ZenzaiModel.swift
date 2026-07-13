import Foundation
import Crypto

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ZenzaiModel {
    public static let downloadURL = URL(
        string: "https://github.com/kazormia296/grimodex-models/releases/download/"
            + "zenzai-v3-small-q5km-v1/zenzai-v3-small-Q5_K_M.gguf"
    )!
    public static let sha256 =
        "501f605d088f5b988791a00ae19ed46985ed7c48144f364b2f3f1f951c9b2083"

    public static var modelDirectoryURL: URL {
        #if os(macOS)
        AppGroup.applicationSupportDirectoryURL()
            .appendingPathComponent("zenzai", isDirectory: true)
        #else
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
            .appendingPathComponent("azooKey", isDirectory: true)
            .appendingPathComponent("zenzai", isDirectory: true)
        #endif
    }

    public static var modelURL: URL {
        modelDirectoryURL.appendingPathComponent("zenzai.gguf", isDirectory: false)
    }

    public static func isInstalledModel() -> Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
    }

    public enum DownloadError: LocalizedError {
        case invalidResponse
        case checksumMismatch

        public var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Zenzaiモデルのサーバー応答が不正です"
            case .checksumMismatch:
                return "Zenzaiモデルの整合性チェックに失敗しました"
            }
        }
    }

    public static func isValidInstalledModel() -> Bool {
        guard let data = try? Data(contentsOf: modelURL) else {
            return false
        }
        return checksum(for: data) == sha256
    }

    public static func download() async throws {
        let (temporaryURL, response) = try await URLSession.shared.download(
            from: downloadURL
        )
        guard let response = response as? HTTPURLResponse,
              (200 ..< 300).contains(response.statusCode) else {
            throw DownloadError.invalidResponse
        }

        let data = try Data(contentsOf: temporaryURL)
        guard checksum(for: data) == sha256 else {
            throw DownloadError.checksumMismatch
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: modelDirectoryURL,
            withIntermediateDirectories: true
        )
        let partialURL = modelURL.appendingPathExtension("download")
        if fileManager.fileExists(atPath: partialURL.path) {
            try fileManager.removeItem(at: partialURL)
        }
        if fileManager.fileExists(atPath: modelURL.path) {
            try fileManager.removeItem(at: modelURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: partialURL)
        try fileManager.moveItem(at: partialURL, to: modelURL)
    }

    private static func checksum(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
