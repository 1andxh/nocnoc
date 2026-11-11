import Foundation
import NocnocCore

// nocnoc-mcp — stdio MCP server exposing `ask_user`. The agent starts this
// process; we read JSON-RPC lines on stdin and answer on stdout. stdout is
// the protocol channel: never print anything else there.

let socketPath = ProcessInfo.processInfo.environment["NOCNOC_SOCKET"]
    ?? NSHomeDirectory() + "/Library/Application Support/nocnoc/nocnoc.sock"
// Claude Code sets CLAUDE_PROJECT_DIR for stdio servers; otherwise use our cwd.
let projectDir = ProcessInfo.processInfo.environment["CLAUDE_PROJECT_DIR"]
    ?? FileManager.default.currentDirectoryPath

let outLock = NSLock()
let server = MCPServer(
    projectDir: projectDir,
    send: { data in
        outLock.lock(); defer { outLock.unlock() }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    },
    ask: AppAsker.make(socketPath: socketPath)
)

FileHandle.standardError.write(Data("nocnoc-mcp \(Router.version) ready (socket \(socketPath))\n".utf8))

while let line = readLine(strippingNewline: true) {
    if line.isEmpty { continue }
    server.handle(line: Data(line.utf8))
}

// stdin closed: the agent is gone. Cancel pending asks so their panels close.
server.cancelAll()
Thread.sleep(forTimeInterval: 0.2)
