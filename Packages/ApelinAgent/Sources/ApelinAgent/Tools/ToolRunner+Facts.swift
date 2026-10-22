import KWWKAI

extension ToolRunner {
    func gatherFacts(_ tool: InvocationFacts.Tool, arguments: JSONValue) async throws -> InvocationFacts {
        guard case let .local(name) = tool else { return InvocationFacts(tool: tool) }
        var facts = InvocationFacts(tool: tool)
        switch name {
        case .writeFile, .patchFile, .createFile:
            let path = try arguments.requireString("path")
            // No project walk for .git files here: a git directory does not
            // change the gate's answer, and the tool's own resolution walks.
            facts.pathCheck = check { _ = try root.resolveForWrite(path, findingGitPointers: false) }
        case .readFile:
            let path = try arguments.requireString("path")
            facts.pathCheck = check { _ = try root.resolveExisting(path) }
        case .list, .grep, .find:
            let path = arguments.argString("path") ?? "."
            facts.pathCheck = check { _ = try root.resolveExisting(path) }
        case .runCode:
            facts.command = try CommandClassifier.classify(arguments)
            let cwd = arguments.argString("cwd") ?? "."
            facts.pathCheck = root.mayReach(cwd) ? .inside : .outside(cwd)
            facts.workingDirectory = cwd
        case .build:
            facts.description = try? await digests.state(of: .build, for: project)
        case .install:
            facts.description = try? await digests.state(of: .packaging, for: project)
        case .removePackage:
            facts.installationID = try arguments.requireString("installation_id")
        case .gitPush:
            // The branch the card names is the one pushed: an omitted one is
            // read now and sent explicitly.
            var branch = arguments.argNonEmptyString("branch")
            if branch == nil {
                let status = try? await backend.gitStatus(GitStatusToolRequest(context: HostCallContext(
                    sessionID: sessionID,
                    project: project,
                    toolCallID: "",
                    approval: .notRequired,
                )))
                branch = status?.branch
            }
            facts.push = GitPushTarget(remote: arguments.argNonEmptyString("remote") ?? "origin", branch: branch)
        case .gitSetAuthor:
            facts.gitSettings = "the commit author"
        case .gitSaveCredential:
            let host = arguments.argString("host") ?? ""
            let username = arguments.argString("username") ?? ""
            facts.gitSettings = "the credential for \(host) (user \(username))"
        case .gitRemoveCredential:
            facts.gitSettings = "the credential for \(arguments.argString("host") ?? "")"
        case .confirmLoaded where arguments.argBool("respring") == true:
            // It resprings the device, so it is gated as respring is.
            facts.tool = .local(.respring)
        default:
            break
        }
        return facts
    }

    /// `.outside` when resolution refuses the path as leaving the project
    /// (including a symbolic link it will not write through); `.inside`
    /// otherwise — a missing file is the tool's error to report.
    private func check(_ resolve: () throws -> Void) -> InvocationFacts.PathCheck {
        do {
            try resolve()
            return .inside
        } catch let error as PathPolicyError {
            switch error {
            case let .outsideRoot(path), let .symlinkRefused(path): return .outside(path)
            case .embeddedNUL: return .outside("a path with a NUL byte")
            default: return .inside
            }
        } catch {
            return .inside
        }
    }
}
