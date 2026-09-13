import Foundation
import Testing

@testable import SandboxKit

@Test func workspaceRejectsTraversalAndSymlinks() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["../private", "/etc/passwd", "a/b", "..", "a\\b"] {
        #expect(throws: (any Error).self) { try WorkspaceFiles.file(name, in: root) }
    }
    try FileManager.default.createSymbolicLink(
        at: root.appending(path: "escape"), withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
    #expect(throws: (any Error).self) { try WorkspaceFiles.read("escape", in: root) }
    try Data("hello".utf8).write(to: root.appending(path: "valid.txt"))
    #expect(try WorkspaceFiles.read("valid.txt", in: root) == Data("hello".utf8))
    #expect(
        try WorkspaceFiles.read("valid.txt", in: URL(fileURLWithPath: root.path, isDirectory: true))
            == Data("hello".utf8))
    #expect(throws: (any Error).self) { try WorkspaceFiles.read("valid.txt", in: root, limit: 2) }
}
@Test func missingVMNeverFallsBackToHost() async throws {
    let vm = Sandbox(root: URL(fileURLWithPath: "/tmp/pepito-no-vm"))
    await #expect(throws: (any Error).self) { try await vm.script(language: "shell", code: "echo unsafe") }
}
