import Foundation

public struct GrimodexClientContext: Codable, Equatable, Sendable {
    public let bundleIdentifier: String?
    public let secureInput: Bool
    public let generation: UInt64

    public init(
        bundleIdentifier: String?,
        secureInput: Bool,
        generation: UInt64 = 0
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.secureInput = secureInput
        self.generation = generation
    }
}

public enum GrimodexScopeMode: String, Codable, CaseIterable, Sendable {
    case off
    case grimodexOnly
    case allApplications

    public static let defaultValue = GrimodexScopeMode.grimodexOnly
}

public enum GrimodexScopeReason: Equatable, Sendable {
    case allowedGrimodex
    case allowedAllApplications
    case disabled
    case secureInput
    case unknownProgram
    case otherProgram
}

public struct GrimodexScopeDecision: Equatable, Sendable {
    public let allowsGrimodexIntegration: Bool
    public let allowsLearning: Bool
    public let reason: GrimodexScopeReason

    public init(
        allowsGrimodexIntegration: Bool,
        allowsLearning: Bool,
        reason: GrimodexScopeReason
    ) {
        self.allowsGrimodexIntegration = allowsGrimodexIntegration
        self.allowsLearning = allowsLearning
        self.reason = reason
    }
}

public enum GrimodexScopePolicy {
    private static let grimodexBundleIdentifier = "com.miyakey.grimodex"

    public static func evaluate(
        mode: GrimodexScopeMode,
        context: GrimodexClientContext
    ) -> GrimodexScopeDecision {
        if context.secureInput {
            return GrimodexScopeDecision(
                allowsGrimodexIntegration: false,
                allowsLearning: false,
                reason: .secureInput
            )
        }

        switch mode {
        case .off:
            return GrimodexScopeDecision(
                allowsGrimodexIntegration: false,
                allowsLearning: true,
                reason: .disabled
            )
        case .allApplications:
            return GrimodexScopeDecision(
                allowsGrimodexIntegration: true,
                allowsLearning: true,
                reason: .allowedAllApplications
            )
        case .grimodexOnly:
            guard let bundleIdentifier = context.bundleIdentifier, !bundleIdentifier.isEmpty else {
                return GrimodexScopeDecision(
                    allowsGrimodexIntegration: false,
                    allowsLearning: true,
                    reason: .unknownProgram
                )
            }
            if bundleIdentifier == grimodexBundleIdentifier {
                return GrimodexScopeDecision(
                    allowsGrimodexIntegration: true,
                    allowsLearning: true,
                    reason: .allowedGrimodex
                )
            }
            return GrimodexScopeDecision(
                allowsGrimodexIntegration: false,
                allowsLearning: true,
                reason: .otherProgram
            )
        }
    }
}

public struct GrimodexIntegrationRevision: Equatable, Sendable {
    public let generation: UInt64
    public let payload: GrimodexIntegrationPayload?
    public let allowsLearning: Bool
    public let secureInput: Bool

    public init(
        generation: UInt64,
        payload: GrimodexIntegrationPayload?,
        allowsLearning: Bool = true,
        secureInput: Bool = false
    ) {
        self.generation = generation
        self.payload = payload
        self.allowsLearning = allowsLearning
        self.secureInput = secureInput
    }

    public init(
        snapshot: GrimodexPublishedSnapshot,
        decision: GrimodexScopeDecision
    ) {
        self.init(
            generation: snapshot.generation,
            payload: decision.allowsGrimodexIntegration ? snapshot.payload : nil,
            allowsLearning: decision.allowsLearning,
            secureInput: decision.reason == .secureInput
        )
    }
}

public protocol GrimodexRevisionProviding: Sendable {
    func latest() -> GrimodexIntegrationRevision
}

public struct GrimodexDisabledRevisionProvider: GrimodexRevisionProviding, Sendable {
    public init() {}

    public func latest() -> GrimodexIntegrationRevision {
        GrimodexIntegrationRevision(generation: 0, payload: nil)
    }
}

public struct GrimodexCompositionGenerationPin: Equatable, Sendable {
    public private(set) var applied: GrimodexIntegrationRevision?
    public private(set) var pending: GrimodexIntegrationRevision?
    public private(set) var pinned: GrimodexIntegrationRevision?

    public init() {}

    public var isComposing: Bool { pinned != nil }

    public mutating func observe(
        _ revision: GrimodexIntegrationRevision
    ) -> GrimodexIntegrationRevision? {
        let baseline = pending ?? pinned ?? applied
        if let baseline {
            guard revision.generation >= baseline.generation else {
                return nil
            }
            guard revision != baseline else {
                return nil
            }
        }

        if isComposing {
            pending = revision
            return nil
        }
        applied = revision
        pending = nil
        return revision
    }

    public mutating func beginComposition(
        latest: GrimodexIntegrationRevision
    ) -> GrimodexIntegrationRevision? {
        if isComposing {
            _ = observe(latest)
            return nil
        }
        let revisionToApply = observe(latest)
        pinned = applied
        return revisionToApply
    }

    public mutating func endComposition(
        latest: GrimodexIntegrationRevision
    ) -> GrimodexIntegrationRevision? {
        guard isComposing else {
            return observe(latest)
        }
        _ = observe(latest)
        pinned = nil
        guard let next = pending else {
            return nil
        }
        pending = nil
        guard applied != next else {
            return nil
        }
        applied = next
        return next
    }

    public mutating func revokeImmediately(
        _ revision: GrimodexIntegrationRevision
    ) -> GrimodexIntegrationRevision? {
        let newestGeneration = [
            revision.generation,
            applied?.generation,
            pending?.generation,
            pinned?.generation,
        ].compactMap { $0 }.max() ?? revision.generation
        let revoked = GrimodexIntegrationRevision(
            generation: newestGeneration,
            payload: nil,
            allowsLearning: false,
            secureInput: true
        )
        pinned = nil
        pending = nil
        guard applied != revoked else {
            return nil
        }
        applied = revoked
        return revoked
    }
}
