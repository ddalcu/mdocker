import Foundation

/// `mdocker compose [-f file] [-p name] up|down|ps|logs|exec`. Every container carries mdocker.* labels,
/// so there is no state file: the engine's own listing is the source of truth.
enum Compose {
    static func main(_ argv: [String]) -> Int32 {
        var args = argv
        var file: String?, name: String?
        while let flag = args.first, ["-f", "-p", "--file", "--project-name"].contains(flag), args.count > 1 {
            if flag == "-f" || flag == "--file" { file = args[1] } else { name = args[1] }
            args.removeFirst(2)
        }
        guard let cmd = args.first else { print("usage: mdocker compose [-f file] [-p name] up|down|ps|logs|exec"); return 1 }
        let rest = Array(args.dropFirst())
        do {
            let project = try Project.load(file: file, name: name)
            Engine.ensureStarted()
            switch cmd {
            case "up": return try up(project, services: rest.filter { !$0.hasPrefix("-") })
            case "down": return down(project, volumes: rest.contains("-v") || rest.contains("--volumes"))
            case "ps": return ps(project)
            case "logs": return logs(project, args: rest)
            case "exec": return exec(project, args: rest)
            default: throw ComposeError("unknown compose command: \(cmd)")
            }
        } catch {
            warn("\(error)")
            return 1
        }
    }

    /// Always detached; follow output with `mdocker compose logs -f`.
    static func up(_ p: Project, services: [String]) throws -> Int32 {
        p.warnUnsupported()
        try FileManager.default.createDirectory(at: p.home, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: p.hostsFile.path) { FileManager.default.createFile(atPath: p.hostsFile.path, contents: nil) }
        refreshHosts(p)
        for (v, def) in p.volumes.sorted(by: { $0.key < $1.key }) {
            if p.isExternal(v) {
                guard Engine.run(["volume", "inspect", p.volumeName(v)], quiet: true) == 0 else {
                    throw ComposeError("external volume \(p.volumeName(v)) not found")
                }
                continue
            }
            let labels = ["mdocker.project": p.name].merging(Dictionary(uniqueKeysWithValues: Project.pairs(def["labels"]).map { ($0.0, $0.1 ?? "") })) { _, new in new }
            Engine.run(["volume", "create"] + labels.sorted(by: { $0.key < $1.key }).flatMap { ["--label", "\($0.key)=\($0.value)"] } + [p.volumeName(v)], quiet: true)
        }
        for svc in try p.order(services) {
            if let build = p.buildArgs(svc), Engine.run(build) != 0 { return 1 }
            let args = p.runArgs(svc)
            Engine.makeBindDirs(args)
            let existing = Engine.boxes(project: p.name).first { $0.service == svc }
            if let e = existing, e.running, e.configuration.labels["mdocker.hash"] == label(args, "mdocker.hash") {
                print("\(p.containerName(svc)) up-to-date")
                continue
            }
            if existing != nil { Engine.run(["rm", "-f", p.containerName(svc)], quiet: true) }
            guard Engine.run(["run", "-d"] + args, quiet: true) == 0 else {
                warn("\(svc) failed to start; see `mdocker compose logs \(svc)`")
                return 1
            }
            refreshHosts(p)
            print("\(p.containerName(svc)) started")
        }
        return 0
    }

    static func down(_ p: Project, volumes: Bool) -> Int32 {
        var anonymous: [String] = []
        for b in Engine.boxes(project: p.name) {
            anonymous += b.anonymousVolumes
            Engine.run(["rm", "-f", b.name], quiet: true)
            print("\(b.name) removed")
        }
        if volumes {
            for v in p.volumes.keys where !p.isExternal(v) { Engine.run(["volume", "rm", p.volumeName(v)], quiet: true) }
            for v in anonymous { Engine.run(["volume", "rm", v], quiet: true) }
        }
        try? FileManager.default.removeItem(at: p.home)
        return 0
    }

    static func ps(_ p: Project) -> Int32 {
        let rows = Engine.boxes(project: p.name).map { [$0.name, $0.service, $0.configuration.image.reference, $0.status.state, $0.ip ?? "-"] }
        let table = [["NAME", "SERVICE", "IMAGE", "STATE", "IP"]] + rows
        let widths = (0..<5).map { c in table.map { $0[c].count }.max()! }
        for row in table { print(zip(row, widths).map { $0.padding(toLength: $1 + 2, withPad: " ", startingAt: 0) }.joined()) }
        return 0
    }

    /// Concurrent `container logs` per service, each line prefixed with its service.
    static func logs(_ p: Project, args: [String]) -> Int32 {
        let flags = args.filter { $0.hasPrefix("-") }.map { $0 == "--tail" ? "-n" : $0 }
        // a bare number is the value of --tail/-n, not a service
        let names = args.filter { !$0.hasPrefix("-") && Int($0) == nil }
        let boxes = Engine.boxes(project: p.name).filter { names.isEmpty || names.contains($0.service) }
        let lock = NSLock()
        let group = DispatchGroup()
        for b in boxes {
            let proc = Engine.process(["logs"] + flags + [b.name])
            let pipe = Pipe()
            proc.standardOutput = pipe
            guard (try? proc.run()) != nil else { continue }
            group.enter()
            DispatchQueue.global().async {
                var buffer = Data()
                while case let chunk = pipe.fileHandleForReading.availableData, !chunk.isEmpty {
                    buffer += chunk
                    while let nl = buffer.firstIndex(of: 10) {
                        let line = String(decoding: buffer[..<nl], as: UTF8.self)
                        buffer.removeSubrange(...nl)
                        lock.lock(); print("\(b.service) | \(line)"); fflush(stdout); lock.unlock()
                    }
                }
                group.leave()
            }
        }
        group.wait()
        return 0
    }

    /// `exec [flags] service cmd...` → `container exec [flags] <container> cmd...` (-T is a no-op here).
    static func exec(_ p: Project, args: [String]) -> Int32 {
        guard let i = args.firstIndex(where: { !$0.hasPrefix("-") }) else { warn("usage: exec [flags] service cmd..."); return 1 }
        let flags = args[..<i].filter { $0 != "-T" }
        Engine.exec(["exec"] + flags + [p.containerName(args[i])] + args[(i + 1)...])
    }

    /// Rewrites the shared /etc/hosts in place (a rename would orphan the containers' bind mount).
    static func refreshHosts(_ p: Project) {
        var text = "127.0.0.1 localhost\n"
        for b in Engine.boxes(project: p.name) where b.running {
            if let ip = b.ip { text += "\(ip) \(b.service) \(b.name)\n" }
        }
        guard let fh = try? FileHandle(forWritingTo: p.hostsFile) else { return }
        defer { try? fh.close() }
        let data = Data(text.utf8)
        try? fh.seek(toOffset: 0)
        try? fh.write(contentsOf: data)
        try? fh.truncate(atOffset: UInt64(data.count))
    }

    private static func label(_ args: [String], _ key: String) -> String? {
        args.first { $0.hasPrefix("\(key)=") }.map { String($0.dropFirst(key.count + 1)) }
    }
}
