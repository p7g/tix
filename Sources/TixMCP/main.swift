import Foundation
import Logging
import MCP
import TixCore

/// The MCP Swift SDK 0.12.x models `capabilities.experimental` as a string map,
/// while Codex correctly sends extension values as JSON objects. The server does
/// not use client experimental capabilities, so remove only that incompatible
/// field before the SDK decodes the initialization request.
actor CodexCompatibleStdioTransport: Transport {
    private let base = StdioTransport()
    nonisolated let logger: Logger

    init() {
        logger = base.logger
    }

    func connect() async throws { try await base.connect() }
    func disconnect() async { await base.disconnect() }
    func send(_ data: Data) async throws { try await base.send(data) }

    func receive() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await data in await base.receive() {
                        continuation.yield(sanitize(data))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func sanitize(_ data: Data) -> Data {
        guard var message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              message["method"] as? String == "initialize",
              var parameters = message["params"] as? [String: Any],
              var capabilities = parameters["capabilities"] as? [String: Any],
              capabilities["experimental"] is [String: Any] else { return data }
        capabilities.removeValue(forKey: "experimental")
        parameters["capabilities"] = capabilities
        message["params"] = parameters
        return (try? JSONSerialization.data(withJSONObject: message)) ?? data
    }
}

func schema(_ properties: [String: Value], required: [String] = []) -> Value {
    .object(["type": .string("object"), "properties": .object(properties), "required": .array(required.map(Value.string)), "additionalProperties": .bool(false)])
}
let string: Value = .object(["type": .string("string")])
let integer: Value = .object(["type": .string("integer"), "minimum": .int(1)])
let tools: [Tool] = [
    Tool(name: "list_tickets", description: "List tickets with optional status and readiness filters. Ready means open with all prerequisites done.", inputSchema: schema(["status": .object(["type": .string("string"), "enum": .array([.string("open"), .string("active"), .string("done")])]), "ready": .object(["type": .string("boolean")])])),
    Tool(name: "get_ticket", description: "Read a ticket including revision, prerequisite, dependent, and blocker IDs.", inputSchema: schema(["id": integer], required: ["id"])),
    Tool(name: "create_ticket", description: "Create an open ticket. Only a title is required.", inputSchema: schema(["title": string, "body": string], required: ["title"])),
    Tool(name: "edit_ticket", description: "Edit title or Markdown body. Supply expectedRevision from get_ticket to reject stale edits; omit only for deliberate overwrite.", inputSchema: schema(["id": integer, "title": string, "body": string, "expectedRevision": integer], required: ["id"])),
    Tool(name: "add_dependency", description: "Make id depend on prerequisite. Rejects cycles and duplicate edges.", inputSchema: schema(["id": integer, "prerequisite": integer], required: ["id", "prerequisite"])),
    Tool(name: "remove_dependency", description: "Remove a declared prerequisite from a ticket.", inputSchema: schema(["id": integer, "prerequisite": integer], required: ["id", "prerequisite"])),
    Tool(name: "claim_ticket", description: "Atomically claim a ready ticket for owner and mark it active. Conflicts return current ticket state.", inputSchema: schema(["id": integer, "owner": string], required: ["id", "owner"])),
    Tool(name: "release_ticket", description: "Return an active ticket to open and clear its owner.", inputSchema: schema(["id": integer], required: ["id"])),
    Tool(name: "complete_ticket", description: "Explicitly mark an open or active ticket done, retaining its owner.", inputSchema: schema(["id": integer], required: ["id"])),
    Tool(name: "reopen_ticket", description: "Return a done ticket to open and clear its owner.", inputSchema: schema(["id": integer], required: ["id"]))
]

func result(_ object: Value, isError: Bool = false) throws -> CallTool.Result {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return .init(content: [.text(text: String(decoding: try encoder.encode(object), as: UTF8.self), annotations: nil, _meta: nil)], structuredContent: Optional.some(object), isError: isError)
}
func ticketValue(_ ticket: Ticket) throws -> Value {
    var fields = try Value(ticket).objectValue!
    fields["ready"] = .bool(ticket.ready); fields["displayID"] = .string(ticket.displayID)
    return .object(fields)
}
func handle(_ params: CallTool.Parameters, store: TicketStore) throws -> CallTool.Result {
    guard let tool = tools.first(where: { $0.name == params.name }) else { throw TixError.invalid("Unknown tool: \(params.name)") }
    let args = params.arguments ?? [:]
    let properties = tool.inputSchema.objectValue!["properties"]!.objectValue!
    for (key, value) in args {
        guard let property = properties[key]?.objectValue else { throw TixError.invalid("Unknown argument: \(key)") }
        switch property["type"]?.stringValue {
        case "string": guard value.stringValue != nil else { throw TixError.invalid("\(key) must be a string.") }
        case "integer": guard let number = value.intValue, number > 0 else { throw TixError.invalid("\(key) must be a positive integer.") }
        case "boolean": guard value.boolValue != nil else { throw TixError.invalid("\(key) must be a boolean.") }
        default: break
        }
    }
    for key in tool.inputSchema.objectValue!["required"]!.arrayValue!.compactMap(\.stringValue) where args[key] == nil {
        throw TixError.invalid("Missing required argument: \(key)")
    }
    let id = Int64(args["id"]?.intValue ?? 0)
    let ticket: Ticket
    switch params.name {
    case "list_tickets":
        let status = args["status"]?.stringValue.flatMap(TicketStatus.init(rawValue:))
        if args["status"] != nil && status == nil { throw TixError.invalid("Status must be open, active, or done.") }
        return try result(.object(["tickets": .array(try store.list(status: status, ready: args["ready"]?.boolValue).map(ticketValue))]))
    case "get_ticket": ticket = try store.get(id)
    case "create_ticket": ticket = try store.create(title: args["title"]!.stringValue!, body: args["body"]?.stringValue ?? "")
    case "edit_ticket":
        guard args["title"] != nil || args["body"] != nil else { throw TixError.invalid("Supply title or body to edit.") }
        ticket = try store.edit(id, title: args["title"]?.stringValue, body: args["body"]?.stringValue, expectedRevision: args["expectedRevision"]?.intValue.map(Int64.init))
    case "add_dependency": ticket = try store.addDependency(id, prerequisite: Int64(args["prerequisite"]!.intValue!))
    case "remove_dependency": ticket = try store.removeDependency(id, prerequisite: Int64(args["prerequisite"]!.intValue!))
    case "claim_ticket": ticket = try store.claim(id, owner: args["owner"]!.stringValue!)
    case "release_ticket": ticket = try store.transition(id, .release)
    case "complete_ticket": ticket = try store.transition(id, .complete)
    case "reopen_ticket": ticket = try store.transition(id, .reopen)
    default: throw TixError.invalid("Unknown tool.")
    }
    return try result(.object(["ticket": try ticketValue(ticket)]))
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--help"] {
    print("Usage: tix-mcp --database /absolute/path/to/workspace/tickets.sqlite\nOpen an existing Tix workspace over MCP stdio. Create workspaces in the Tix app.")
} else {
    do {
        guard arguments.count == 2, arguments[0] == "--database", arguments[1].hasPrefix("/") else {
            throw TixError.invalid("Usage: tix-mcp --database /absolute/path/to/workspace/tickets.sqlite")
        }
        let store = try TicketStore(path: arguments[1])
        let server = Server(name: "tix", version: "0.1.0", capabilities: .init(tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }
        await server.withMethodHandler(CallTool.self) { params in
            do { return try handle(params, store: store) }
            catch TixError.conflict(let ticket) {
                return try result(.object(["error": .string(TixError.conflict(ticket).localizedDescription), "code": .string("conflict"), "ticket": try ticketValue(ticket)]), isError: true)
            } catch {
                return try result(.object(["error": .string(error.localizedDescription), "code": .string("invalid_operation")]), isError: true)
            }
        }
        try await server.start(transport: CodexCompatibleStdioTransport())
        await server.waitUntilCompleted()
    } catch {
        FileHandle.standardError.write(Data("tix-mcp: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
