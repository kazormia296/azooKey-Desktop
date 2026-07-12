@testable import Core
import Foundation
import Testing

private final class GrimodexFixtureSandbox {
    let rootURL: URL

    init() throws {
        self.rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GrimodexPhase5Tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: self.rootURL.appendingPathComponent("projects", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: self.rootURL)
    }

    func installState(_ data: Data) throws {
        try data.write(to: self.rootURL.appendingPathComponent("state.json"))
    }

    func installProject(_ data: Data, id: String = "project-a") throws {
        try data.write(to: self.rootURL.appendingPathComponent("projects/\(id).json"))
    }
}

private final class ScriptedGrimodexFileReader: GrimodexFileReading, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [Data]
    private let project: Data

    init(states: [Data], project: Data) {
        self.states = states
        self.project = project
    }

    func read(_ url: URL, maxBytes _: Int) throws -> Data? {
        self.lock.lock()
        defer { self.lock.unlock() }
        if url.lastPathComponent == "state.json" {
            guard !self.states.isEmpty else { return nil }
            return self.states.removeFirst()
        }
        return self.project
    }
}

private enum GrimodexContractFixture {
    static func state(
        formatVersion: Int = 1,
        activeProjectID: String? = "project-a",
        updatedAt: String = "2026-07-11T00:00:00.000Z"
    ) throws -> Data {
        let activeProjectValue: Any
        if let activeProjectID {
            activeProjectValue = activeProjectID
        } else {
            activeProjectValue = NSNull()
        }
        return try JSONSerialization.data(withJSONObject: [
            "format_version": formatVersion,
            "active_project_id": activeProjectValue,
            "updated_at": updatedAt
        ], options: [.sortedKeys])
    }

    static func entry(
        yomi: String,
        surface: String,
        category: String,
        priority: Int,
        entryID: String
    ) -> [String: Any] {
        [
            "yomi": yomi,
            "surface": surface,
            "category": category,
            "priority": priority,
            "entry_id": entryID
        ]
    }

    static func project(
        formatVersion: Int = 1,
        projectID: String = "project-a",
        projectName: String = "星海年代記",
        generatedAt: String = "2026-07-11T00:00:00.000Z",
        entries: [[String: Any]],
        topic: String? = nil
    ) throws -> Data {
        var object: [String: Any] = [
            "format_version": formatVersion,
            "project_id": projectID,
            "project_name": projectName,
            "generated_at": generatedAt,
            "entries": entries,
            "profile": "軍事SF。宇宙植民地を舞台にした物語。"
        ]
        if let topic {
            object["zenzai_context"] = [
                "topic": topic,
                "style": NSNull(),
                "preference": NSNull()
            ]
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

@Test func grimodexV1MapsAndDeduplicatesEntriesAndBoundsZenzaiTopic() throws {
    let sandbox = try GrimodexFixtureSandbox()
    let entries = [
        GrimodexContractFixture.entry(
            yomi: "せつな",
            surface: "刹那",
            category: "person",
            priority: 2,
            entryID: "entry-setsuna"
        ),
        GrimodexContractFixture.entry(
            yomi: "せつな",
            surface: "刹那",
            category: "person",
            priority: 1,
            entryID: "entry-setsuna-low"
        ),
        GrimodexContractFixture.entry(
            yomi: "りゅうせいこう",
            surface: "龍星港",
            category: "place",
            priority: 1,
            entryID: "entry-port"
        ),
        GrimodexContractFixture.entry(
            yomi: "きどうれき",
            surface: "軌道暦",
            category: "noun",
            priority: 2,
            entryID: "entry-calendar"
        )
    ]
    try sandbox.installState(GrimodexContractFixture.state())
    try sandbox.installProject(GrimodexContractFixture.project(
        entries: entries,
        topic: "1234567890123456789012345・後半は切り捨て"
    ))

    let result = GrimodexSnapshotLoader(rootURL: sandbox.rootURL).load()

    #expect(result.diagnostic == .loaded)
    guard let payload = result.payload else {
        Issue.record("Expected a valid Grimodex V1 payload")
        return
    }
    #expect(payload.projectID == "project-a")
    #expect(payload.projectName == "星海年代記")
    #expect(payload.dictionaryEntries.count == 3)
    #expect(payload.dictionaryEntries.first(where: { $0.entryID == "entry-setsuna" }) == GrimodexMappedDictionaryEntry(
        ruby: "セツナ",
        word: "刹那",
        cid: 1289,
        mid: 501,
        value: -5,
        entryID: "entry-setsuna"
    ))
    #expect(payload.dictionaryEntries.first(where: { $0.entryID == "entry-port" }) == GrimodexMappedDictionaryEntry(
        ruby: "リュウセイコウ",
        word: "龍星港",
        cid: 1293,
        mid: 501,
        value: -9,
        entryID: "entry-port"
    ))
    #expect(payload.dictionaryEntries.first(where: { $0.entryID == "entry-calendar" }) == GrimodexMappedDictionaryEntry(
        ruby: "キドウレキ",
        word: "軌道暦",
        cid: 1288,
        mid: 501,
        value: -6,
        entryID: "entry-calendar"
    ))
    #expect(!payload.dictionaryEntries.contains { $0.entryID == "entry-setsuna-low" })
    #expect(payload.conditions.topic == "1234567890123456789012345")
    #expect(payload.conditions.topic?.unicodeScalars.count == 25)
    #expect(payload.conditions.style == nil)
    #expect(payload.conditions.preference == nil)
}

@Test func grimodexV1RejectsOversizedStateProjectAndEntryArray() throws {
    let oversizedState = try GrimodexFixtureSandbox()
    try oversizedState.installState(Data(repeating: 0x20, count: 65_537))
    let stateResult = GrimodexSnapshotLoader(rootURL: oversizedState.rootURL).load()
    #expect(stateResult.payload == nil)
    #expect(stateResult.diagnostic == .invalidState)

    let oversizedProject = try GrimodexFixtureSandbox()
    try oversizedProject.installState(GrimodexContractFixture.state())
    try oversizedProject.installProject(Data(repeating: 0x20, count: 16_777_217))
    let projectResult = GrimodexSnapshotLoader(rootURL: oversizedProject.rootURL).load()
    #expect(projectResult.payload == nil)
    #expect(projectResult.diagnostic == .invalidSnapshot)

    let tooManyEntries = try GrimodexFixtureSandbox()
    let repeatedEntry = GrimodexContractFixture.entry(
        yomi: "せつな",
        surface: "刹那",
        category: "person",
        priority: 2,
        entryID: "entry-setsuna"
    )
    try tooManyEntries.installState(GrimodexContractFixture.state())
    try tooManyEntries.installProject(GrimodexContractFixture.project(
        entries: Array(repeating: repeatedEntry, count: 20_001)
    ))
    let entryCountResult = GrimodexSnapshotLoader(rootURL: tooManyEntries.rootURL).load()
    #expect(entryCountResult.payload == nil)
    #expect(entryCountResult.diagnostic == .invalidSnapshot)
}

@Test func grimodexV1InvalidAndTraversalPayloadsFailClosed() throws {
    let unsupportedState = try GrimodexFixtureSandbox()
    try unsupportedState.installState(GrimodexContractFixture.state(formatVersion: 2))
    let unsupportedStateResult = GrimodexSnapshotLoader(rootURL: unsupportedState.rootURL).load()
    #expect(unsupportedStateResult.payload == nil)
    #expect(unsupportedStateResult.diagnostic == .invalidState)

    let traversalState = try GrimodexFixtureSandbox()
    try traversalState.installState(GrimodexContractFixture.state(activeProjectID: "../project-a"))
    let traversalStateResult = GrimodexSnapshotLoader(rootURL: traversalState.rootURL).load()
    #expect(traversalStateResult.payload == nil)
    #expect(traversalStateResult.diagnostic == .invalidState)

    let unknownCategory = try GrimodexFixtureSandbox()
    try unknownCategory.installState(GrimodexContractFixture.state())
    try unknownCategory.installProject(GrimodexContractFixture.project(entries: [
        GrimodexContractFixture.entry(
            yomi: "せつな",
            surface: "刹那",
            category: "unknown",
            priority: 2,
            entryID: "entry-setsuna"
        )
    ]))
    let unknownCategoryResult = GrimodexSnapshotLoader(rootURL: unknownCategory.rootURL).load()
    #expect(unknownCategoryResult.payload == nil)
    #expect(unknownCategoryResult.diagnostic == .invalidSnapshot)

    let traversalProject = try GrimodexFixtureSandbox()
    try traversalProject.installState(GrimodexContractFixture.state())
    try traversalProject.installProject(GrimodexContractFixture.project(
        projectID: "../project-a",
        entries: []
    ))
    let traversalProjectResult = GrimodexSnapshotLoader(rootURL: traversalProject.rootURL).load()
    #expect(traversalProjectResult.payload == nil)
    #expect(traversalProjectResult.diagnostic == .invalidSnapshot)
}

@Test func grimodexV1DoubleReadsStateBeforePublishingAProject() throws {
    let sandbox = try GrimodexFixtureSandbox()
    let stateA = try GrimodexContractFixture.state()
    let stateB = try GrimodexContractFixture.state(
        activeProjectID: "project-b",
        updatedAt: "2026-07-11T00:00:01.000Z"
    )
    let projectA = try GrimodexContractFixture.project(entries: [])
    let reader = ScriptedGrimodexFileReader(states: [stateA, stateB], project: projectA)

    let result = GrimodexSnapshotLoader(rootURL: sandbox.rootURL, fileReader: reader).load()

    #expect(result.payload == nil)
    #expect(result.diagnostic == .stateChangedDuringRead)
}

@Test func grimodexSnapshotManagerAdvancesGenerationOnlyForSemanticChanges() throws {
    let sandbox = try GrimodexFixtureSandbox()
    let entries = [
        GrimodexContractFixture.entry(
            yomi: "せつな",
            surface: "刹那",
            category: "person",
            priority: 2,
            entryID: "entry-setsuna"
        )
    ]
    try sandbox.installState(GrimodexContractFixture.state())
    try sandbox.installProject(GrimodexContractFixture.project(entries: entries))
    let manager = GrimodexSnapshotManager(loader: GrimodexSnapshotLoader(rootURL: sandbox.rootURL))

    let initial: GrimodexPublishedSnapshot = manager.reload()
    #expect(initial.generation == 1)
    #expect(initial.payload != nil)

    try sandbox.installProject(GrimodexContractFixture.project(
        generatedAt: "2026-07-11T00:00:01.000Z",
        entries: entries
    ))
    #expect(manager.reload().generation == 1)

    var changedEntries = entries
    changedEntries[0]["surface"] = "刹那改"
    try sandbox.installProject(GrimodexContractFixture.project(
        generatedAt: "2026-07-11T00:00:02.000Z",
        entries: changedEntries
    ))
    let changed = manager.reload()
    #expect(changed.generation == 2)
    #expect(changed.payload?.dictionaryEntries.first?.word == "刹那改")
}
