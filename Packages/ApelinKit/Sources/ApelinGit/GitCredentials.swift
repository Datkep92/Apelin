internal import GitKit
import Foundation

/// An HTTPS sign-in: a user name and a token sent as the password.
public struct GitCredential: Sendable, Equatable {
    public var username: String
    public var token: String

    public init(username: String, token: String) {
        self.username = username
        self.token = token
    }
}

/// Answers the credential to offer the remote at a URL, or nil. Asked only
/// for an `https://` URL, with the URL libgit2 is connecting to — the one a
/// redirect led to, if any — so the answer is keyed on where it would go.
public typealias GitCredentialLookup = @Sendable (String) -> GitCredential?

/// The name a credential is saved under, and the only thing a remote's URL
/// is matched on.
public enum GitCredentialHost {
    /// The host of an `https://` URL, lowercased, with `:port` when the URL
    /// names one; nil for any other scheme, a URL with a user or password in
    /// it, or one whose host cannot be told from a port. A saved credential
    /// is offered only when its host equals this exactly: `example.com`
    /// is not `example.com:443`, and neither is `www.example.com`.
    public static func key(of url: String) -> String? {
        guard let components = URLComponents(string: url),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              let host = components.host?.lowercased(), !host.isEmpty, !host.contains(":")
        else { return nil }
        if let port = components.port {
            return "\(host):\(port)"
        }
        return host
    }
}

/// The libgit2 remote callbacks one fetch or push runs with: progress that
/// can stop it, the reference updates it made, the updates a push had
/// refused, and at most one credential.
///
/// The credential is offered once per operation. libgit2 asks again when
/// the remote turns it down, and would go on asking; the second question is
/// answered with an error, which `failure` reports as an authentication
/// failure rather than whatever libgit2 says about an aborted callback.
final class RemoteCallbacks {
    private let credentials: GitCredentialLookup?
    var fetchProgress: ((GitCloneProgress) -> Bool)?
    var pushProgress: ((GitPushProgress) -> Bool)?
    private(set) var updates: [GitRefUpdate] = []
    private(set) var rejections: [(ref: String, status: String)] = []

    private var offered = false
    private var refusedBy: String?
    private var unanswered: String?

    init(credentials: GitCredentialLookup?) {
        self.credentials = credentials
    }

    /// Points `callbacks` at this object. The caller keeps it alive across
    /// the libgit2 call (`withExtendedLifetime`).
    func install(_ callbacks: inout git_remote_callbacks) {
        callbacks.payload = Unmanaged.passUnretained(self).toOpaque()
        // The C call stays in the closure, where `out`'s type is inferred:
        // the macOS and iOS slices of the framework import `git_credential`
        // differently, a struct in one and an opaque type in the other.
        callbacks.credentials = { out, url, _, allowed, payload in
            guard let out, let url, let payload,
                  let credential = RemoteCallbacks.from(payload).offer(url: String(cString: url), allowed: allowed)
            else { return GIT_EAUTH.rawValue }
            return git_credential_userpass_plaintext_new(out, credential.username, credential.token)
        }
        callbacks.transfer_progress = { stats, payload in
            guard let stats, let payload else { return 0 }
            let progress = RemoteCallbacks.from(payload).fetchProgress
            let keepGoing = progress?(GitCloneProgress(
                receivedObjects: Int(stats.pointee.received_objects),
                indexedObjects: Int(stats.pointee.indexed_objects),
                totalObjects: Int(stats.pointee.total_objects),
                receivedBytes: Int(stats.pointee.received_bytes),
            )) ?? true
            return keepGoing ? 0 : GIT_EUSER.rawValue
        }
        callbacks.push_transfer_progress = { current, total, bytes, payload in
            guard let payload else { return 0 }
            let progress = RemoteCallbacks.from(payload).pushProgress
            let keepGoing = progress?(GitPushProgress(current: Int(current), total: Int(total), bytes: Int(bytes)))
                ?? true
            return keepGoing ? 0 : GIT_EUSER.rawValue
        }
        callbacks.update_refs = { name, old, new, _, payload in
            guard let name, let new, let payload else { return 0 }
            let from = old.flatMap { git_oid_is_zero($0) != 0 ? nil : GitRepository.hex($0) }
            RemoteCallbacks.from(payload).updates.append(GitRefUpdate(
                ref: String(cString: name),
                from: from,
                to: GitRepository.hex(new),
            ))
            return 0
        }
        callbacks.push_update_reference = { name, status, payload in
            guard let name, let status, let payload else { return 0 }
            RemoteCallbacks.from(payload).rejections.append((String(cString: name), String(cString: status)))
            return 0
        }
    }

    /// What a failed libgit2 call that ran with these callbacks means.
    func failure(_ code: Int32, _ what: String) -> GitError {
        if code == GIT_EUSER.rawValue {
            return GitError(.cancelled, "\(what) was stopped")
        }
        if let refusedBy {
            return GitError(
                .authenticationFailed,
                "\(what): authentication failed: \(refusedBy) refused the saved credential",
            )
        }
        if let unanswered {
            return GitError(
                .authenticationFailed,
                "\(what): authentication failed: \(unanswered) asks for a sign-in, and no credential is saved for it",
            )
        }
        return GitError.last(code, what)
    }

    /// The credential to answer libgit2's question with, or nil when there
    /// is none to give — or when it is asking again, after the remote turned
    /// the first one down.
    private func offer(url: String, allowed: UInt32) -> GitCredential? {
        let host = GitCredentialHost.key(of: url) ?? URLComponents(string: url)?.host ?? "the remote"
        guard !offered else {
            refusedBy = host
            return nil
        }
        guard allowed & GIT_CREDENTIAL_USERPASS_PLAINTEXT.rawValue != 0,
              GitCredentialHost.key(of: url) != nil,
              let credential = credentials?(url),
              !credential.username.utf8.contains(0), !credential.token.utf8.contains(0)
        else {
            unanswered = host
            return nil
        }
        offered = true
        return credential
    }

    private static func from(_ payload: UnsafeMutableRawPointer) -> RemoteCallbacks {
        Unmanaged<RemoteCallbacks>.fromOpaque(payload).takeUnretainedValue()
    }
}
