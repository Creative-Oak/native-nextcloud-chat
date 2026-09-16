import Foundation
import Testing
@testable import TalkCore

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

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

    // MARK: - isAttachableFile

    @Test("An ordinary file is attachable")
    func acceptsRegularFile() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("kvidr-tests-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let file = root.appendingPathComponent("report.pdf")
        try Data("hello".utf8).write(to: file)
        #expect(file.isAttachableFile)
    }

    @Test("A directory is not")
    func refusesDirectory() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("kvidr-tests-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        #expect(!root.isAttachableFile)
    }

    @Test("A named pipe is not, which is the one that would never finish")
    func refusesNamedPipe() throws {
        // The predicate is what is tested, not the read: a test that actually handed a FIFO
        // to `Data(contentsOf:)` to prove the point would hang the suite rather than fail it,
        // which is exactly the bug. `mkfifo` and then ask.
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("kvidr-tests-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let fifo = root.appendingPathComponent("report.pdf")
        let made = mkfifo(fifo.path, 0o600)
        try #require(made == 0)
        #expect(!fifo.isAttachableFile)
    }

    @Test("A character device is not either")
    func refusesCharacterDevice() {
        // `/dev/zero` is readable, is not a directory, and answers forever.
        let device = URL(fileURLWithPath: "/dev/zero")
        #expect(device.isLocalFile)
        #expect(!device.isAttachableFile)
    }

    @Test("A path with nothing at it is not")
    func refusesMissingFile() {
        let missing = URL(fileURLWithPath: "/var/empty/kvidr-\(UUID().uuidString)/report.pdf")
        #expect(!missing.isAttachableFile)
    }

    @Test("Nothing that fails isLocalFile can pass isAttachableFile")
    func refusesEverythingIsLocalFileRefuses() throws {
        let link = try #require(URL(string: "https://cloud.example.com/secret"))
        #expect(!link.isAttachableFile)
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

        await #expect(throws: TalkError.fileNotAttachable) {
            _ = try await service.upload(transfer, folder: "/Talk", progress: { _ in })
        }
        // The point of the test: nothing was fetched and nothing was put in the user's Files.
        #expect(transport.requestCount == 0)
    }

    @Test("Uploading something that is not a regular file is refused at the same door")
    func uploadRefusesDirectory() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("kvidr-tests-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let transport = StubTransport(json: "")
        let server = try ServerAddress.parse("https://cloud.example.com")
        let credentials = Credentials(loginName: "alice", appPassword: "pw")
        let service = AttachmentService(
            server: server,
            credentials: credentials,
            userID: "alice",
            transport: transport,
            client: OCSClient(server: server, credentials: credentials, transport: transport)
        )

        let transfer = FileTransfer(fileURL: root, byteCount: 0)
        await #expect(throws: TalkError.fileNotAttachable) {
            _ = try await service.upload(transfer, folder: "/Talk", progress: { _ in })
        }
        #expect(transport.requestCount == 0)
    }

    @Test("A real file is streamed from disk, not read into the request")
    func uploadStreamsFile() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("kvidr-tests-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let file = root.appendingPathComponent("report.pdf")
        try Data("hello".utf8).write(to: file)

        let transport = StubTransport(json: "", status: 201)
        let server = try ServerAddress.parse("https://cloud.example.com")
        let credentials = Credentials(loginName: "alice", appPassword: "pw")
        let service = AttachmentService(
            server: server,
            credentials: credentials,
            userID: "alice",
            transport: transport,
            client: OCSClient(server: server, credentials: credentials, transport: transport)
        )

        // The byte count the transfer carries is stale on purpose: the one sent is asked fresh.
        let path = try await service.upload(FileTransfer(fileURL: file, byteCount: 999), folder: "/Talk", progress: { _ in })

        let request = try #require(transport.lastRequest)
        #expect(path == "/Talk/report.pdf")
        #expect(request.bodyFile == file)
        #expect(request.body == nil)
        #expect(request.headers["OC-Total-Length"] == "5")
    }

    // MARK: - FileInspection

    @Test("A file system that never answers is given up on at the deadline")
    func inspectionGivesUp() async {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let started = ContinuousClock.now

        let answer = await FileInspection.inspect(
            URL(fileURLWithPath: "/Volumes/share/report.pdf"),
            deadline: 0.1,
            probe: { _ in
                // Stands in for a `stat` on a wedged mount: blocks until the test is over.
                release.wait()
                return .regularFile(byteCount: 1)
            }
        )

        #expect(answer == .notAnswering)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test("An answer before the deadline is the answer")
    func inspectionAnswers() async {
        let answer = await FileInspection.inspect(
            URL(fileURLWithPath: "/Users/alice/report.pdf"),
            deadline: 10,
            probe: { _ in .regularFile(byteCount: 42) }
        )
        #expect(answer == .regularFile(byteCount: 42))
    }

    @Test("The probe sizes a file and refuses a pipe")
    func probe() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("kvidr-tests-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let file = root.appendingPathComponent("report.pdf")
        try Data("hello".utf8).write(to: file)
        #expect(FileInspection.probe(file) == .regularFile(byteCount: 5))

        let fifo = root.appendingPathComponent("pipe.pdf")
        try #require(mkfifo(fifo.path, 0o600) == 0)
        #expect(FileInspection.probe(fifo) == .notAttachable)
        #expect(FileInspection.probe(root.appendingPathComponent("gone.pdf")) == .missing)
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

@Suite("Reading a small file off the caller")
struct FileInspectionReadTests {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kvidr-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("A file is read whole")
    func readsFile() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("me.jpg")
        try Data("picture".utf8).write(to: file)
        #expect(try await FileInspection.read(file, maximumBytes: 100) == Data("picture".utf8))
    }

    @Test("Each way it can fail says which", arguments: ["big", "missing", "folder", "link"])
    func failures(_ kind: String) async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let url: URL
        let expected: TalkError
        switch kind {
        case "big":
            url = root.appendingPathComponent("big.jpg")
            try Data(count: 200).write(to: url)
            expected = .fileTooLarge
        case "missing":
            url = root.appendingPathComponent("gone.jpg")
            expected = .fileMissing
        case "folder":
            url = root
            expected = .fileNotAttachable
        default:
            url = try #require(URL(string: "https://cloud.example.com/me.jpg"))
            expected = .fileNotAttachable
        }
        await #expect(throws: expected) {
            _ = try await FileInspection.read(url, maximumBytes: 100)
        }
    }
}
