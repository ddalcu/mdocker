import Foundation

/// Thin wrapper over Apple's `container` CLI — the only thing that talks to the engine.
enum Engine {
    static func process(_ args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["container"] + args
        return p
    }

    /// Runs `container args` with inherited stdio; returns the exit status.
    @discardableResult
    static func run(_ args: [String], quiet: Bool = false) -> Int32 {
        let p = process(args)
        if quiet { p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice }
        do { try p.run() } catch { return 127 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    static func output(_ args: [String]) -> Data {
        let p = process(args)
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch { return Data() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }

    /// Starts the engine (apiserver + kernel) if it isn't already running.
    static func ensureStarted() {
        if run(["system", "status"], quiet: true) != 0 {
            run(["system", "start", "--enable-kernel-install"])
        }
    }

    /// Docker creates a missing host directory for `-v /host:/ctr`; `container` errors instead.
    static func makeBindDirs(_ args: [String]) {
        var i = 0
        while i < args.count {
            var spec: String?
            if ["-v", "--volume"].contains(args[i]), i + 1 < args.count { spec = args[i + 1]; i += 1 }
            else if let flag = ["--volume=", "-v="].first(where: args[i].hasPrefix) { spec = String(args[i].dropFirst(flag.count)) }
            if let src = spec?.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first, let c = src.first, ".~/".contains(c) {
                try? FileManager.default.createDirectory(atPath: (String(src) as NSString).expandingTildeInPath, withIntermediateDirectories: true)
            }
            i += 1
        }
    }

    /// Replaces this process with `container args`.
    static func exec(_ args: [String]) -> Never {
        let argv = (["container"] + args).map { strdup($0) } + [nil]
        execvp("container", argv)
        perror("mdocker: cannot exec `container` (brew install container)")
        exit(127)
    }

    struct Box: Decodable {
        struct Config: Decodable {
            let id: String
            let labels: [String: String]
            let image: Image
            let mounts: [Mount]?
        }
        struct Mount: Decodable {
            struct Kind: Decodable {
                struct Volume: Decodable { let name: String }
                let volume: Volume?
            }
            let type: Kind
        }
        struct Image: Decodable { let reference: String }
        struct Status: Decodable {
            let state: String
            let networks: [Net]?
        }
        struct Net: Decodable { let ipv4Address: String }

        let configuration: Config
        let status: Status

        var name: String { configuration.id }
        var service: String { configuration.labels["mdocker.service"] ?? "" }
        /// Volumes `run -v /path` created on its own: engine-named with a UUID.
        var anonymousVolumes: [String] {
            (configuration.mounts ?? []).compactMap { $0.type.volume?.name }
                .filter { UUID(uuidString: $0) != nil }
        }
        var running: Bool { status.state == "running" }
        var ip: String? {
            status.networks?.first?.ipv4Address.split(separator: "/").first.map(String.init)
        }
    }

    /// All containers (any state) carrying this compose project's label.
    static func boxes(project: String) -> [Box] {
        let data = output(["ls", "-a", "--format", "json"])
        let all = (try? JSONDecoder().decode([Box].self, from: data)) ?? []
        return all.filter { $0.configuration.labels["mdocker.project"] == project }
    }
}
