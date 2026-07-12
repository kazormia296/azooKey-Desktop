@testable import Core
import Foundation
import Testing

@Test func grimodexMacPathResolverUsesTheSharedApplicationSupportContract() {
    let home = URL(fileURLWithPath: "/Users/author", isDirectory: true)

    #expect(
        GrimodexPathResolver.resolve(environment: [:], homeDirectory: home).path
            == "/Users/author/Library/Application Support/com.miyakey.grimodex/ime"
    )
    #expect(
        GrimodexPathResolver.resolve(
            environment: ["GRIMODEX_IME_ROOT": "/tmp/phase5-contract"],
            homeDirectory: home
        ).path == "/tmp/phase5-contract"
    )
}

@Test func grimodexConsumerRegistrarWritesAndRemovesTheCanonicalMacHandshake() throws {
    let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(
        "GrimodexConsumerRegistrarTests-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: sandbox) }
    let registrar = GrimodexConsumerRegistrar(
        rootURL: sandbox,
        version: "0.1.0",
        now: { Date(timeIntervalSince1970: 1_783_728_000) },
        heartbeatInterval: 900
    )

    let handshakeURL = try registrar.registerNow()
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: handshakeURL)) as? [String: Any]
    )

    #expect(handshakeURL.lastPathComponent == "azookey-grimodex.json")
    #expect(object["format_version"] as? Int == 1)
    #expect(object["consumer_id"] as? String == "azookey-grimodex")
    #expect(object["name"] as? String == "Grimodex IME for macOS")
    #expect(object["version"] as? String == "0.1.0")
    #expect(object["platform"] as? String == "macos")
    let capabilities = try #require(object["capabilities"] as? [String: Bool])
    #expect(capabilities == [
        "profile": true,
        "dynamic_dictionary": true,
        "zenzai_v3_conditions": true,
        "application_scoping": true
    ])
    #expect(object["last_seen"] as? String == "2026-07-11T00:00:00.000Z")

    let fileAttributes = try FileManager.default.attributesOfItem(atPath: handshakeURL.path)
    #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let directoryAttributes = try FileManager.default.attributesOfItem(
        atPath: handshakeURL.deletingLastPathComponent().path
    )
    #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

    try registrar.unregister()
    #expect(!FileManager.default.fileExists(atPath: handshakeURL.path))
}

@Test func grimodexConsumerRegistrarPublishesTheProtocolHeartbeatInterval() {
    #expect(GrimodexConsumerRegistrar.heartbeatInterval == 900)
}
