import Foundation
import Testing

@testable import AgentKit

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
