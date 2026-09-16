# Tix

A local macOS ticket table for coordinating humans and coding agents. View work in **waves** (dependency layers) or **lanes** (a Git-log-style graph beside ticket rows). Both surfaces use the same transactional SQLite core.

## Build and run

Requires macOS 14 or later and a Swift 6.2 toolchain (Xcode 26). The first build downloads Swift packages; normal use is entirely local.

```sh
./scripts/package.sh
open dist/Tix.app
```

The script builds for the current Mac architecture and ad-hoc signs `dist/Tix.app`. It bundles the independent server at `dist/Tix.app/Contents/MacOS/tix-mcp`. You can move the app to Applications and use that installed path in MCP configuration. This is a local build, not a notarized distribution.

For development, `swift run Tix` launches the app and `swift build` builds both executables. Open `Package.swift` in Xcode for debugging.

## Workspaces

Choose **New Workspace** and select a new folder name outside a Git checkout, such as `~/Tix Workspaces/Turkey`. The folder contains `tickets.sqlite` and SQLite's WAL/SHM sidecars while connections are open. **Open Workspace** selects an existing folder. Recent workspaces are remembered locally.

Point every agent working on that ticket collection at the same absolute database path, including agents using different Git worktrees. No app window needs to remain open for MCP access. Use a local disk, not a network or cloud-synchronized directory. To copy a workspace, quit the app and stop its MCP processes first, then copy the entire folder.

## Ticket workflow

- Enter a title and press Return to create a ticket; Command-N focuses the entry field.
- Select a row to edit its title and Markdown description. Command-S saves. Preview displays inline Markdown formatting with preserved line breaks.
- Add prerequisites in the detail pane. Links navigate to related tickets; the minus button removes a prerequisite.
- **Claim** a ready ticket with an owner name. **Release** returns active work to open; **Complete** marks it done; **Reopen** clears the owner and returns it to open.
- Drafts survive switching rows. If another process changes a ticket you are editing, explicitly **Reload** or **Overwrite** its title and description. Saving normally checks the ticket revision atomically.

An open ticket is ready when all its prerequisites are done. Active work remains active if a prerequisite is reopened or added; its blockers are shown. Completing work is an explicit action and is permitted even if prerequisites remain unfinished. Owner names are coordination metadata, not authorization.

**Waves:** unfinished tickets are grouped by longest unfinished prerequisite chain. Completed prerequisites cut the chain. Active tickets stay in their layer. Completed tickets have a collapsible section.

**Lanes:** every ticket, including completed tickets, appears in stable topological order within its connected group. Independent groups stay together, ordered by their lowest ticket ID; standalone tickets never interrupt another group's tracks. Tracks branch and join in the left gutter. A bridge/gap at an intermediate crossing means no connection; a dot identifies the row's ticket. Rows cannot be independently sorted because their order carries graph meaning.

Within each group, deterministic heuristics favor closing open tracks and finishing nearby branches, trying two tie-breaks for branching tickets. Tix compares those layouts with ID-based topological ordering and chooses by lane count, total vertical track length, then horizontal travel. This keeps the best of three candidates without an expensive search for a global optimum. Waves retain their existing ordering.

Readiness represents declared dependencies only. Tix does not inspect source files, predict code conflicts, launch agents, or manage branches.

## MCP configuration

Configure your MCP client to launch the bundled server over stdio:

```json
{
  "mcpServers": {
    "tix": {
      "command": "/absolute/path/to/Tix.app/Contents/MacOS/tix-mcp",
      "args": ["--database", "/absolute/path/to/Turkey/tickets.sqlite"]
    }
  }
}
```

Adapt the surrounding configuration format to your client. Both paths must be absolute. The workspace must already exist; create it in the app first. Each client can launch its own server process against the shared database. Only protocol messages are written to stdout.

| Tool | Arguments |
| --- | --- |
| `list_tickets` | optional `status` (`open`, `active`, `done`), `ready` (boolean) |
| `get_ticket` | `id` |
| `create_ticket` | `title`, optional `body` |
| `edit_ticket` | `id`, `title` and/or `body`, optional `expectedRevision` |
| `add_dependency` / `remove_dependency` | `id`, `prerequisite` |
| `claim_ticket` | `id`, `owner` |
| `release_ticket` / `complete_ticket` / `reopen_ticket` | `id` |

IDs are positive integers on the wire, displayed as `TIX-123` in the UI. Results contain either `ticket` or `tickets`, with `ready`, `displayID`, prerequisite/dependent/blocker IDs, revision, and Unix timestamp fields. Tool results include structured JSON and the same JSON as text. Errors set `isError` and provide `code` and `error`; claim/edit conflicts also include the current `ticket`.

Agents should read before editing and pass `expectedRevision`. Omitting it explicitly overwrites the supplied fields. Claims are atomic: exactly one competing claimant wins. No automatic lease expiration or agent liveness detection is performed.

## Architecture

- `TixCore`: ticket model, deterministic graph layout, and GRDB-backed SQLite operations.
- `TixApp`: SwiftUI workspace and editor around an AppKit `NSTableView`, with native row sizing and a graph gutter.
- `TixMCP`: the official Swift MCP SDK with ten focused tools.

Both processes open the same file. GRDB write transactions acquire SQLite's write lock before checking conditions, so competing claims and dependency edits serialize safely. WAL allows readers alongside a writer. Foreign keys, checks, and a five-second busy timeout are enabled. A versioned migration creates tickets and prerequisite edges; revisions prevent stale editor saves. The app polls `data_version` on its persistent connection once a second while visible and refreshes on activation and local writes.

## Validation

```sh
swift test
python3 scripts/test_mcp.py
# Verify the actual packaged executable as well:
python3 scripts/test_mcp.py dist/Tix.app/Contents/MacOS/tix-mcp
```

Tests cover wave layering, cycles, track reuse and crossings, dependency rollback, revision conflicts, cross-connection refresh detection, competing claims, and opposing dependency edits. The stdio smoke test covers initialization, all tools, two live processes, error responses, and clean EOF shutdown.

Manual checks: create/open a workspace, keyboard ticket capture and selection, scrolling in lanes, dependency editing, completed groups, and an external MCP edit while a human draft is unsaved.
