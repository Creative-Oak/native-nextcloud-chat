import Foundation
import Testing
@testable import TalkCore

/// The rules the upload path applies to a URL before it reads or deletes anything.
///
/// A dropped or pasted `URL` is untrusted input: `.dropDestination(for: URL.self)` matches
/// `public.url`, so a hyperlink and a document are the same type by the time they arrive.
@Suite("What the upload path will read, and what it will delete")
struct AttachmentUploadGuardTests {
    // MARK: - isLocalFile

    @Test("A local file is readable", arguments: [
        "file:///Users/alice/Documents/report.pdf",
        "file:///etc/hosts",
        "file://localhost/Users/alice/report.pdf",
        "file:///Users/alice/a%20file%20with%20spaces.png"
    ])
    func acceptsLocalFiles(_ input: String) throws {
        let url = try #require(URL(string: input))
        #expect(url.isLocalFile)
    }

    @Test("Anything that would be fetched rather than read is refused", arguments: [
        "https://cloud.example.com/secret",
        "http://127.0.0.1:8080/admin",
        "http://169.254.169.254/latest/meta-data/iam/security-credentials/",
        "http://[::1]/admin",
        "ftp://files.example.com/pub/x",
        "smb://attacker.example/share",
        "data:text/plain;base64,aGk=",
        "x-vendor-scheme://do-something"
    ])
    func refusesEverythingElse(_ input: String) throws {
        let url = try #require(URL(string: input))
        #expect(!url.isLocalFile)
    }

    @Test("A file URL that names another machine is refused")
    func refusesRemoteFileURL() throws {
        let url = try #require(URL(string: "file://attacker.example/share/secrets"))
        // Still a file URL as far as Foundation is concerned — the host is what gives it away.
        #expect(url.isFileURL)
        #expect(!url.isLocalFile)
    }

    @Test("A URL built from a path is always local")
    func fileURLWithPath() {
        #expect(URL(fileURLWithPath: "/Users/alice/report.pdf").isLocalFile)
    }

    // MARK: - The read itself

    @Test("Uploading a web URL neither fetches it nor sends a request")
    func uploadRefusesWebURL() async throws {
        let transport = StubTransport(json: "")
        let service = AttachmentService(
            server: try ServerAddress.parse("https://cloud.example.com"),
            credentials: Credentials(loginName: "alice", appPassword: "pw"),
            userID: "alice",
            transport: transport,
            client: OCSClient(
                server: try ServerAddress.parse("https://cloud.example.com"),
                credentials: Credentials(loginName: "alice", appPassword: "pw"),
                transport: transport
            )
        )

        let link = try #require(URL(string: "http://169.254.169.254/latest/meta-data/"))
        let transfer = FileTransfer(fileURL: link, byteCount: 0)

        await #expect(throws: TalkError.unexpectedResponse("Only files on this Mac can be attached")) {
            _ = try await service.upload(transfer, folder: "/Talk", progress: { _ in })
        }
        // The point of the test: nothing was fetched and nothing was put in the user's Files.
        #expect(transport.requestCount == 0)
    }

    // MARK: - isContained(in:)

    @Test("A file inside the directory is contained")
    func containedFile() {
        let directory = URL(fileURLWithPath: "/var/folders/ab/T/kvidr", isDirectory: true)
        #expect(directory.appendingPathComponent("photo.png").isContained(in: directory))
        #expect(directory.appendingPathComponent("A1B2").appendingPathComponent("photo.png")
            .isContained(in: directory))
    }

    @Test("A sibling whose name merely starts the same way is not")
    func siblingIsNotContained() {
        // The bug this replaces: a bare `hasPrefix` on the path says yes to both of these.
        let directory = URL(fileURLWithPath: "/var/folders/ab/T/kvidr", isDirectory: true)
        #expect(!URL(fileURLWithPath: "/var/folders/ab/T/kvidrX/photo.png").isContained(in: directory))
        #expect(!URL(fileURLWithPath: "/var/folders/ab/T/kvidr-other/photo.png").isContained(in: directory))
    }

    @Test("The directory does not contain itself")
    func directoryIsNotInsideItself() {
        let directory = URL(fileURLWithPath: "/var/folders/ab/T/kvidr", isDirectory: true)
        #expect(!directory.isContained(in: directory))
        #expect(!URL(fileURLWithPath: "/var/folders/ab/T/kvidr").isContained(in: directory))
    }

    @Test("A path that walks back out is not contained")
    func traversalIsNotContained() {
        let directory = URL(fileURLWithPath: "/var/folders/ab/T/kvidr", isDirectory: true)
        let escape = URL(fileURLWithPath: "/var/folders/ab/T/kvidr/../secrets/id_rsa")
        #expect(!escape.isContained(in: directory))
    }

    @Test("A trailing separator on the directory makes no difference")
    func trailingSeparator() {
        let withSlash = URL(fileURLWithPath: "/var/folders/ab/T/kvidr/", isDirectory: true)
        let withoutSlash = URL(fileURLWithPath: "/var/folders/ab/T/kvidr", isDirectory: false)
        let file = URL(fileURLWithPath: "/var/folders/ab/T/kvidr/photo.png")
        #expect(file.isContained(in: withSlash))
        #expect(file.isContained(in: withoutSlash))
    }

    @Test("An unrelated directory is not contained")
    func unrelatedDirectory() {
        let directory = URL(fileURLWithPath: "/var/folders/ab/T/kvidr", isDirectory: true)
        #expect(!URL(fileURLWithPath: "/Users/alice/.ssh/id_rsa").isContained(in: directory))
    }

    @Test("A URL that is not a file URL is never contained")
    func nonFileURLIsNotContained() throws {
        let directory = URL(fileURLWithPath: "/var/folders/ab/T/kvidr", isDirectory: true)
        let web = try #require(URL(string: "https://cloud.example.com/var/folders/ab/T/kvidr/x"))
        #expect(!web.isContained(in: directory))
    }

    @Test("Containment survives a directory that really is a symlink")
    func resolvesSymlinks() throws {
        // The one case a component comparison on unresolved paths gets wrong: two spellings
        // of the same directory. Done against the real filesystem, since that is the only
        // way to have a symlink to resolve.
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("kvidr-tests-\(UUID().uuidString)")
        let real = root.appendingPathComponent("real", isDirectory: true)
        try manager.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let link = root.appendingPathComponent("link", isDirectory: true)
        try manager.createSymbolicLink(at: link, withDestinationURL: real)

        let file = real.appendingPathComponent("photo.png")
        try Data("x".utf8).write(to: file)

        #expect(file.isContained(in: link))
        #expect(link.appendingPathComponent("photo.png").isContained(in: real))
    }
}
