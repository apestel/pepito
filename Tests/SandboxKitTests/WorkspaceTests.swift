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
    try FileManager.default.linkItem(at: root.appending(path: "valid.txt"), to: root.appending(path: "linked.txt"))
    #expect(throws: (any Error).self) { try WorkspaceFiles.read("linked.txt", in: root) }

}
@Test func missingRuntimeNeverFallsBackToHost() async throws {
    let vm = Sandbox(
        root: URL(fileURLWithPath: "/tmp/pepito-no-runtime"),
        runtime: URL(fileURLWithPath: "/missing"))
    await #expect(throws: (any Error).self) {
        try await vm.script(language: "shell", code: "echo unsafe")
    }
}

@Test func scriptReturnsCompleteResponseWithoutWaitingForProcessTeardown() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let runtime = root.appending(path: "runtime")
    try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let node = runtime.appending(path: "node")
    // A complete response and EOF must release the caller independently of process teardown.
    try Data("""
        #!/bin/sh
        read request
        printf '%s\\n' '{"stdout":"42","stderr":"","exitCode":0,"duration":0}'
        exec 1>&-
        exec /bin/sleep 3
        """.utf8).write(to: node)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: node.path)
    try Data().write(to: runtime.appending(path: "script-runner.mjs"))
    let sandbox = Sandbox(root: root.appending(path: "work"), runtime: runtime)
    try await sandbox.start()
    let start = ContinuousClock.now
    let result = try await sandbox.script(language: "python", code: "print(42)")
    #expect(result.stdout == "42")
    #expect(result.exitCode == 0)
    #expect(start.duration(to: .now) < .seconds(2))
    await sandbox.stop()
}
