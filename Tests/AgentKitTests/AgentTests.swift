import Foundation
import Testing

@testable import AgentKit

@Test @MainActor func missingRuntimeExplainsRecoveryWithoutDeveloperInstructions() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let node = root.appending(path: "node")
    let bridge = root.appending(path: "bridge.mjs")
    try Data().write(to: bridge)
    // Absence du moteur, fichier non exécutable, puis pont JavaScript absent.
    for state in 0..<3 {
        if state == 1 { try Data("placeholder".utf8).write(to: node) }
        if state == 2 {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: node.path)
            try FileManager.default.removeItem(at: bridge)
        }
        do {
            _ = try AgentProcess().start(runtime: root, node: node, directory: root)
            Issue.record("Un moteur incomplet ne doit pas démarrer")
        } catch let error as AgentError {
            #expect(error.localizedDescription.contains("Quittez puis rouvrez Pépito"))
            #expect(error.localizedDescription.contains("réinstallez"))
            #expect(!error.localizedDescription.contains("build-app.sh"))
        }
    }
}

@Test func fragmentedJSONLPreservesUnicodeAndMultipleEvents() throws {
    let data = Data("{\"type\":\"delta\",\"text\":\"é\u{2028}🙂\"}\n{\"type\":\"done\"}\r\n".utf8)
    var parser = AgentFramer()
    var events: [AgentEvent] = []
    for byte in data { events += try parser.append(Data([byte])) }
    #expect(events.map(\.type) == ["delta", "done"])
    #expect(events[0].text == "é\u{2028}🙂")
    try parser.finish()
}
@Test func truncatedAndOversizedFramesFailClosed() throws {
    var parser = AgentFramer()
    _ = try parser.append(Data("{\"type\":\"delta\"".utf8))
    #expect(throws: (any Error).self) { try parser.finish() }
    var oversized = AgentFramer()
    #expect(throws: (any Error).self) { try oversized.append(Data(repeating: 65, count: 2_097_153)) }
}
