import Foundation
import MLXLMCommon

/// A single-file edit the model has proposed via the `propose_edit` tool.
/// Never written to disk by the tool handler itself -- staged here for the
/// user to review and explicitly apply or reject (see `AppModel.pendingEdits`).
struct PendingEdit: Identifiable, Sendable, Equatable {
    let id = UUID()
    let path: String
    let oldContent: String
    let newContent: String
}

enum WorkspaceToolError: Error, LocalizedError {
    case pathEscapesWorkspace(String)
    var errorDescription: String? {
        switch self {
        case .pathEscapesWorkspace(let path): "Path \"\(path)\" is outside the open workspace."
        }
    }
}

/// Tools scoped to a single opened folder ("workspace"), giving the model
/// real, grounded access to a project via mlx-swift-lm's built-in tool-calling
/// support (`ChatSession(tools:toolDispatch:)`) instead of relying on pasted-in
/// text. Read-only (list/read) plus `propose_edit`, which never writes to disk
/// itself -- it only stages a `PendingEdit` for the user to review.
enum WorkspaceTools {
    /// Matches the truncation limit `AppModel.addAttachments` already applies
    /// to pasted-in files, so a huge file reads the same way whether the model
    /// asked for it or the user attached it.
    private static let maxReadBytes = 200_000
    private static let maxListEntries = 400

    /// Resolves `path` (relative or absolute) against `root`, rejecting anything
    /// that escapes it -- mirrors the HF-cache path containment check in
    /// `MLXService.deleteCachedModel` (`url.standardizedFileURL.path.hasPrefix(...)`).
    static func resolve(_ path: String, in root: URL) throws -> URL {
        let candidate = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        let resolved = candidate.standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard resolved.path == rootPath || resolved.path.hasPrefix(rootPath + "/") else {
            throw WorkspaceToolError.pathEscapesWorkspace(path)
        }
        return resolved
    }

    struct ListDirectoryInput: Codable { var path: String? }
    struct ReadFileInput: Codable { var path: String }
    struct ProposeEditInput: Codable { var path: String; var newContent: String }

    static func listDirectoryTool(root: URL) -> Tool<ListDirectoryInput, String> {
        Tool(
            name: "list_directory",
            description: "Lists files and folders in the open workspace. Use \".\" for the top level.",
            parameters: [
                .optional("path", type: .string, description: "Directory path relative to the workspace root, e.g. \".\" or \"Sources\". Defaults to the root.")
            ]
        ) { input in
            let dirURL = try resolve(input.path ?? ".", in: root)
            guard let entries = FileManager.default.enumerator(
                at: dirURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { return "(directory not found or unreadable)" }
            var lines: [String] = []
            let rootPrefix = root.standardizedFileURL.path + "/"
            // NSEnumerator's Sequence/IteratorProtocol conformance (`for ... in
            // entries`) is unavailable from async contexts (this handler is
            // async); calling the plain Objective-C `nextObject()` method
            // directly sidesteps that, and -- unlike collecting `allObjects`
            // first -- still stops walking the tree as soon as maxListEntries is
            // hit, rather than eagerly crawling a huge directory regardless.
            while let url = entries.nextObject() as? URL {
                if lines.count >= maxListEntries { lines.append("… (truncated, \(maxListEntries)+ entries)"); break }
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let relative = url.standardizedFileURL.path.replacingOccurrences(of: rootPrefix, with: "")
                lines.append(isDir ? "\(relative)/" : relative)
            }
            return lines.isEmpty ? "(empty directory)" : lines.joined(separator: "\n")
        }
    }

    static func readFileTool(root: URL) -> Tool<ReadFileInput, String> {
        Tool(
            name: "read_file",
            description: "Reads a text file's contents from the open workspace.",
            parameters: [
                .required("path", type: .string, description: "File path relative to the workspace root, e.g. \"Sources/App.swift\".")
            ]
        ) { input in
            let fileURL = try resolve(input.path, in: root)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return "(file not found: \(input.path))"
            }
            guard let data = try? Data(contentsOf: fileURL) else { return "(could not read file: \(input.path))" }
            let truncated = data.count > maxReadBytes
            let slice = truncated ? data.prefix(maxReadBytes) : data[...]
            guard let text = String(data: slice, encoding: .utf8) else { return "(file is not text: \(input.path))" }
            return truncated ? text + "\n\n… (truncated, file exceeds \(maxReadBytes) bytes)" : text
        }
    }

    /// `onPropose` hops to `AppModel` (main-actor) to stage the edit for review;
    /// the tool result string only confirms receipt, never whether it will be
    /// applied, so the model can't infer success and act as though the file
    /// already changed.
    static func proposeEditTool(root: URL, onPropose: @escaping @Sendable (PendingEdit) async -> Void) -> Tool<ProposeEditInput, String> {
        Tool(
            name: "propose_edit",
            description: "Proposes replacing a file's full contents with new content. This does NOT write to disk -- it stages the edit for the user to review and explicitly apply.",
            parameters: [
                .required("path", type: .string, description: "File path relative to the workspace root."),
                .required("newContent", type: .string, description: "The complete new contents of the file."),
            ]
        ) { input in
            let fileURL = try resolve(input.path, in: root)
            let oldContent = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            await onPropose(PendingEdit(path: input.path, oldContent: oldContent, newContent: input.newContent))
            return "Edit to \"\(input.path)\" proposed; awaiting user review. Do not assume it has been applied."
        }
    }

    /// Builds the tool specs and the single `toolDispatch` closure `ChatSession`
    /// expects, dispatching by tool name to the matching handler above.
    /// `onActivity` is called with a human-readable description just before each
    /// tool runs and with `nil` just after, purely so the UI can show "using
    /// read_file(App.swift)…" while the model waits on a tool result -- it has
    /// no bearing on the tool-call loop itself.
    static func makeToolSet(
        root: URL,
        onPropose: @escaping @Sendable (PendingEdit) async -> Void,
        onActivity: @escaping @Sendable (String?) async -> Void = { _ in }
    ) -> (tools: [ToolSpec], dispatch: @Sendable (ToolCall) async throws -> String) {
        let listTool = listDirectoryTool(root: root)
        let readTool = readFileTool(root: root)
        let editTool = proposeEditTool(root: root, onPropose: onPropose)
        let dispatch: @Sendable (ToolCall) async throws -> String = { call in
            let path = call.function.arguments["path"]?.anyValue as? String
            await onActivity(path.map { "\(call.function.name)(\($0))" } ?? "\(call.function.name)()")
            do {
                let result: String
                switch call.function.name {
                case listTool.name: result = try await call.execute(with: listTool)
                case readTool.name: result = try await call.execute(with: readTool)
                case editTool.name: result = try await call.execute(with: editTool)
                default: result = "(unknown tool: \(call.function.name))"
                }
                await onActivity(nil)
                return result
            } catch {
                await onActivity(nil)
                throw error
            }
        }
        return ([listTool.schema, readTool.schema, editTool.schema], dispatch)
    }
}
