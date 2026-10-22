internal import GitKit
import Darwin
import Foundation

/// How far a clone has got.
public struct GitCloneProgress: Sendable, Equatable {
    public var receivedObjects: Int
    public var indexedObjects: Int
    public var totalObjects: Int
    public var receivedBytes: Int
}

/// What a clone left behind.
public struct GitCloneResult: Sendable, Equatable {
    /// The commit the branch's tip was at, the one checked out.
    public var commit: String
}

/// What a clone into an existing folder checked out.
public struct GitCloneIntoResult: Sendable, Equatable {
    public var branch: String
    public var commit: String
}

/// A shallow clone of one branch: depth 1, a remote whose only refspec is
/// that branch, no tags. libgit2 has no partial clone, so this is how the
/// SDK manager takes one SDK out of a repository that keeps one per branch,
/// and how a project starts from a repository. A full clone into a folder
/// that is already there (`into`) is how a workspace takes one.
///
/// HTTPS is the transport to use. The libgit2 build runs `ssh` for an SSH
/// URL, and a process that cannot spawn one fails at connect — the callers
/// only pass `https://` (tests also use local paths).
public enum GitClone {
    /// Clones `branch` of `url` into `directory`, which must not exist or be
    /// empty. `credentials` is asked, once, when the remote wants a sign-in.
    /// `progress` is called as objects arrive and stops the clone by
    /// answering false; the clone then throws `GitError` of kind `cancelled`
    /// and leaves a partial folder for the caller to remove.
    public static func shallow(
        url: String,
        branch: String,
        into directory: URL,
        credentials: GitCredentialLookup? = nil,
        progress: @escaping (GitCloneProgress) -> Bool = { _ in true },
    ) throws -> GitCloneResult {
        GitLibrary.ensure()
        guard !branch.isEmpty, !branch.utf8.contains(0), !branch.hasPrefix("-"), !branch.contains(".."),
              !url.utf8.contains(0)
        else {
            throw GitError(.invalid, "bad repository URL or branch")
        }
        let context = CloneContext(branch: branch)
        let callbacks = RemoteCallbacks(credentials: credentials)
        callbacks.fetchProgress = progress

        var options = git_clone_options()
        git_clone_options_init(&options, UInt32(GIT_CLONE_OPTIONS_VERSION))
        options.fetch_opts.depth = 1
        options.fetch_opts.download_tags = GIT_REMOTE_DOWNLOAD_TAGS_NONE
        callbacks.install(&options.fetch_opts.callbacks)
        // libgit2 has no single-branch flag: a remote whose one refspec names
        // the branch is how `git clone --single-branch` is spelled.
        options.remote_cb_payload = Unmanaged.passUnretained(context).toOpaque()
        options.remote_cb = { remote, repository, name, url, payload in
            guard let payload else { return GIT_EINVALID.rawValue }
            let context = Unmanaged<CloneContext>.fromOpaque(payload).takeUnretainedValue()
            let refspec = "+refs/heads/\(context.branch):refs/remotes/origin/\(context.branch)"
            return git_remote_create_with_fetchspec(remote, repository, name, url, refspec)
        }

        var repository: OpaquePointer?
        let code = withExtendedLifetime((context, callbacks)) {
            branch.withCString { name in
                options.checkout_branch = name
                return git_clone(&repository, url, directory.path, &options)
            }
        }
        defer { git_repository_free(repository) }
        guard code == 0 else {
            if code == GIT_EUSER.rawValue {
                throw GitError(.cancelled, "the clone was stopped")
            }
            throw callbacks.failure(code, "clone \(branch)")
        }
        var head: OpaquePointer?
        try GitError.check(git_repository_head(&head, repository), "read the cloned HEAD")
        defer { git_reference_free(head) }
        guard let target = git_reference_target(head) else {
            throw GitError(.failed, "the cloned HEAD is not a commit")
        }
        return GitCloneResult(commit: GitRepository.hex(target))
    }

    /// Makes the folder `directory`, which exists and has no `.git`, the work
    /// tree of a clone of `url`: a repository is initialised in it, `origin`
    /// set to `url` with git's default refspec, fetched in full (not
    /// shallow), and `branch` — nil: the one the remote's HEAD names — made
    /// a local branch tracking `origin/<branch>` and checked out.
    ///
    /// The checkout overwrites nothing: a file the repository has that is
    /// already in the folder throws `conflict`. `excluding` goes into
    /// `.git/info/exclude` first, for the files the caller keeps in the
    /// folder that are not the repository's. Any failure, a stop by
    /// `progress` included, removes the `.git` this made and every file and
    /// folder the checkout wrote, so the folder is as it was.
    public static func into(
        _ directory: URL,
        url: String,
        branch: String? = nil,
        excluding patterns: [String] = [],
        credentials: GitCredentialLookup? = nil,
        progress: @escaping (GitCloneProgress) -> Bool = { _ in true },
    ) throws -> GitCloneIntoResult {
        GitLibrary.ensure()
        guard !url.utf8.contains(0) else { throw GitError(.invalid, "bad repository URL") }
        if let branch {
            try GitRepository.checkBranchName(branch)
        }
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else {
            throw GitError(.notFound, "no folder \(directory.lastPathComponent)")
        }
        let gitDirectory = directory.appendingPathComponent(".git", isDirectory: true)
        guard lstat(gitDirectory.path, &metadata) != 0 else {
            throw GitError(.conflict, "\(directory.lastPathComponent) already has a .git")
        }

        var options = git_repository_init_options()
        git_repository_init_options_init(&options, UInt32(GIT_REPOSITORY_INIT_OPTIONS_VERSION))
        options.flags = GIT_REPOSITORY_INIT_NO_REINIT.rawValue
        var created: OpaquePointer?
        try GitError.check(git_repository_init_ext(&created, directory.path, &options), "make a repository")
        git_repository_free(created)

        let folders = existingFolders(in: directory)
        let checkout = CheckoutRecord()
        do {
            return try fill(
                GitRepository(at: directory),
                url: url,
                branch: branch,
                excluding: patterns,
                checkout: checkout,
                credentials: credentials,
                progress: progress,
            )
        } catch {
            undo(checkout.written, keeping: folders, in: directory)
            try? FileManager.default.removeItem(at: gitDirectory)
            throw error
        }
    }

    /// `into`'s work once the repository is there.
    private static func fill(
        _ repository: GitRepository,
        url: String,
        branch: String?,
        excluding patterns: [String],
        checkout: CheckoutRecord,
        credentials: GitCredentialLookup?,
        progress: @escaping (GitCloneProgress) -> Bool,
    ) throws -> GitCloneIntoResult {
        let pointer = repository.pointer
        var remote: OpaquePointer?
        try GitError.check(git_remote_create(&remote, pointer, "origin", url), "add the remote")
        defer { git_remote_free(remote) }
        let callbacks = RemoteCallbacks(credentials: credentials)
        callbacks.fetchProgress = progress
        var fetch = git_fetch_options()
        git_fetch_options_init(&fetch, UInt32(GIT_FETCH_OPTIONS_VERSION))
        callbacks.install(&fetch.callbacks)
        let code = withExtendedLifetime(callbacks) { git_remote_fetch(remote, nil, &fetch, nil) }
        guard code == 0 else { throw callbacks.failure(code, "fetch \(url)") }

        let name: String
        if let branch {
            name = branch
        } else {
            // The list the fetch read stays readable after it disconnected.
            var buffer = git_buf()
            defer { git_buf_dispose(&buffer) }
            let found = git_remote_default_branch(&buffer, remote)
            guard found == 0, let reference = buffer.ptr.map({ String(cString: $0) }),
                  reference.hasPrefix("refs/heads/")
            else {
                if found == GIT_ENOTFOUND.rawValue || found == 0 {
                    throw GitError(.notFound, "the repository has no branch to check out")
                }
                throw GitError.last(found, "read the remote's default branch")
            }
            name = String(reference.dropFirst("refs/heads/".count))
            try GitRepository.checkBranchName(name)
        }

        var target = git_oid()
        guard git_reference_name_to_id(&target, pointer, "refs/remotes/origin/\(name)") == 0 else {
            throw GitError(.notFound, "the repository has no branch \(name)")
        }
        var commit: OpaquePointer?
        try GitError.check(git_commit_lookup(&commit, pointer, &target), "read \(name)'s commit")
        defer { git_commit_free(commit) }
        var local: OpaquePointer?
        try GitError.check(
            git_reference_create(&local, pointer, "refs/heads/\(name)", &target, 0, "clone: from \(url)"),
            "make the branch \(name)",
        )
        git_reference_free(local)
        try repository.setLocalConfigValue("origin", for: "branch.\(name).remote")
        try repository.setLocalConfigValue("refs/heads/\(name)", for: "branch.\(name).merge")
        try repository.addExcludes(patterns)

        let checkedOut = checkout.run { options in git_checkout_tree(pointer, commit, &options) }
        guard checkedOut == 0 else { throw checkout.failure(checkedOut, "checking out \(name)") }
        try GitError.check(git_repository_set_head(pointer, "refs/heads/\(name)"), "point HEAD at \(name)")
        return GitCloneIntoResult(branch: name, commit: GitRepository.hex(&target))
    }

    /// Every folder below `directory`, as relative paths, outside `.git` and
    /// without following links: what `undo` must leave.
    private static func existingFolders(in directory: URL) -> Set<String> {
        var folders: Set<String> = []
        guard let walk = FileManager.default.enumerator(atPath: directory.path) else { return folders }
        while let relative = walk.nextObject() as? String {
            if relative == ".git" {
                walk.skipDescendants()
                continue
            }
            if (walk.fileAttributes?[.type] as? FileAttributeType) == .typeDirectory {
                folders.insert(relative)
            }
        }
        return folders
    }

    /// Takes back a checkout that failed part way: the files it wrote — none
    /// of which was there before, as it overwrites nothing — then each
    /// folder above one that was not there before and is empty now.
    private static func undo(_ written: [String], keeping folders: Set<String>, in directory: URL) {
        var made: Set<String> = []
        for path in written {
            unlink(directory.appendingPathComponent(path).path)
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty, !folders.contains(parent) {
                made.insert(parent)
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        for folder in made.sorted(by: { $0.count > $1.count }) {
            rmdir(directory.appendingPathComponent(folder).path)
        }
    }

    /// Whether a URL is one the callers accept: HTTPS, nothing else.
    public static func isAcceptedRemote(_ url: String) -> Bool {
        guard let components = URLComponents(string: url), components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil
        else { return false }
        return true
    }
}

/// What a remote advertises, read without fetching anything.
public enum GitRemote {
    /// The branch names under `refs/heads/` the remote at `url` lists,
    /// sorted, optionally only those starting with `prefix`.
    public static func branches(url: String, prefix: String = "") throws -> [String] {
        GitLibrary.ensure()
        guard !url.utf8.contains(0) else { throw GitError(.invalid, "bad repository URL") }
        var remote: OpaquePointer?
        try GitError.check(git_remote_create_detached(&remote, url), "read \(url)")
        defer { git_remote_free(remote) }
        var callbacks = git_remote_callbacks()
        git_remote_init_callbacks(&callbacks, UInt32(GIT_REMOTE_CALLBACKS_VERSION))
        try GitError.check(git_remote_connect(remote, GIT_DIRECTION_FETCH, &callbacks, nil, nil), "connect to \(url)")
        defer { git_remote_disconnect(remote) }
        var heads: UnsafeMutablePointer<UnsafePointer<git_remote_head>?>?
        var count = 0
        try GitError.check(git_remote_ls(&heads, &count, remote), "list \(url)")
        let wanted = "refs/heads/" + prefix
        var names: [String] = []
        for position in 0 ..< count {
            guard let head = heads?[position]?.pointee, let name = head.name else { continue }
            let reference = String(cString: name)
            if reference.hasPrefix(wanted) {
                names.append(String(reference.dropFirst("refs/heads/".count)))
            }
        }
        return names.sorted()
    }
}

private final class CloneContext {
    let branch: String

    init(branch: String) {
        self.branch = branch
    }
}
