import CryptoKit
import Foundation
import Yams

struct ComposeError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

typealias Dict = [String: Any]

/// A parsed compose file: services in dependency order, plus the named volumes it declares.
struct Project {
    let name: String
    let dir: URL
    let services: [String: Dict]
    let volumes: [String]

    var home: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mdocker/\(name)") }
    var hostsFile: URL { home.appendingPathComponent("hosts") }

    static let fileNames = ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]
    /// Keys we translate; anything else on a service is warned about, never silently dropped.
    static let supported: Set<String> = [
        "image", "build", "command", "entrypoint", "environment", "env_file", "ports", "volumes", "depends_on",
        "working_dir", "user", "container_name", "labels", "platform", "init", "read_only",
    ]

    static func load(file: String?, name: String?, env: [String: String] = ProcessInfo.processInfo.environment) throws -> Project {
        let fm = FileManager.default
        guard let path = file ?? fileNames.first(where: fm.fileExists(atPath:)) else {
            throw ComposeError("no compose file found (looked for \(fileNames.joined(separator: ", ")))")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let dir = url.deletingLastPathComponent()
        let dotenv = (try? String(contentsOf: dir.appendingPathComponent(".env"), encoding: .utf8)).map(parseEnv) ?? [:]
        let text = interpolate(try String(contentsOf: url, encoding: .utf8), env: dotenv.merging(env) { _, new in new })
        guard let doc = try Yams.load(yaml: text) as? Dict, let services = doc["services"] as? [String: Dict] else {
            throw ComposeError("\(url.lastPathComponent): no services")
        }
        let project = sanitize(name ?? doc["name"] as? String ?? dir.lastPathComponent)
        return Project(name: project, dir: dir, services: services, volumes: (doc["volumes"] as? Dict)?.keys.sorted() ?? [])
    }

    func warnUnsupported() {
        for (svc, def) in services.sorted(by: { $0.key < $1.key }) {
            for key in def.keys.sorted() where !Self.supported.contains(key) {
                warn("\(svc): `\(key)` is not supported, ignored")
            }
        }
    }

    /// Service names ordered so every service follows its depends_on; `selected` pulls in its dependencies.
    func order(_ selected: [String]) throws -> [String] {
        var out: [String] = []
        var visiting: Set<String> = []
        func visit(_ n: String) throws {
            if out.contains(n) { return }
            guard let def = services[n] else { throw ComposeError("no such service: \(n)") }
            if !visiting.insert(n).inserted { throw ComposeError("depends_on cycle at \(n)") }
            for d in Self.dependencies(def) { try visit(d) }
            out.append(n)
        }
        for n in selected.isEmpty ? services.keys.sorted() : selected { try visit(n) }
        return out
    }

    static func dependencies(_ def: Dict) -> [String] {
        if let m = def["depends_on"] as? Dict { return m.keys.sorted() }
        return list(def["depends_on"])
    }

    func containerName(_ svc: String) -> String { services[svc]?["container_name"] as? String ?? "\(name)-\(svc)" }
    func volumeName(_ v: String) -> String { "\(name)_\(v)" }
    func image(_ svc: String) -> String { services[svc]?["image"] as? String ?? "\(name)-\(svc)" }

    /// `container build` args for a service with a `build:` section, or nil.
    func buildArgs(_ svc: String) -> [String]? {
        guard let b = services[svc]?["build"] else { return nil }
        let spec: Dict = (b as? Dict) ?? ["context": "\(b)"]
        let ctx = path(spec["context"] as? String ?? ".")
        var a = ["build", "-t", image(svc)]
        if let f = spec["dockerfile"] as? String { a += ["-f", URL(fileURLWithPath: f, relativeTo: URL(fileURLWithPath: ctx)).path] }
        if let t = spec["target"] as? String { a += ["--target", t] }
        for (k, v) in Self.pairs(spec["args"]) { a += ["--build-arg", "\(k)=\(v ?? "")"] }
        return a + [ctx]
    }

    /// Args for `container run -d`, ending with the image and command. The hash label makes `up` idempotent.
    func runArgs(_ svc: String) -> [String] {
        let def = services[svc] ?? [:]
        var a = ["--name", containerName(svc), "-v", "\(hostsFile.path):/etc/hosts"]
        for (k, v) in Self.pairs(def["environment"]) { a += ["-e", v.map { "\(k)=\($0)" } ?? k] }
        for f in Self.list(def["env_file"]) { a += ["--env-file", path(f)] }
        for p in Self.list(def["ports"]) { a += ["-p", p] }
        for v in Self.list(def["volumes"]) { a += ["-v", volume(v)] }
        if let w = def["working_dir"] as? String { a += ["-w", w] }
        if let u = def["user"] as? String { a += ["-u", u] }
        if let p = def["platform"] as? String { a += ["--platform", p] }
        if def["init"] as? Bool == true { a.append("--init") }
        if def["read_only"] as? Bool == true { a.append("--read-only") }
        for (k, v) in Self.pairs(def["labels"]) { a += ["-l", "\(k)=\(v ?? "")"] }
        // container takes one --entrypoint word; the rest of a compose entrypoint list leads the command.
        var tail = Self.words(def["command"])
        let entry = Self.words(def["entrypoint"])
        if let e = entry.first { a += ["--entrypoint", e]; tail = Array(entry.dropFirst()) + tail }
        a += [image(svc)] + tail
        let hash = SHA256.hash(data: Data(a.joined(separator: "\0").utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return ["-l", "mdocker.project=\(name)", "-l", "mdocker.service=\(svc)", "-l", "mdocker.hash=\(hash)"] + a
    }

    private func path(_ p: String) -> String {
        let expanded = (p as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, relativeTo: dir).standardizedFileURL.path
    }

    /// `./data:/data:ro` is a bind mount (path resolved against the compose dir); `db:/var/lib` a project-scoped named volume.
    private func volume(_ v: String) -> String {
        var parts = v.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1 else { return v }
        if let first = parts[0].first, ".~/".contains(first) { parts[0] = path(parts[0]) } else { parts[0] = volumeName(parts[0]) }
        return parts.joined(separator: ":")
    }

    // MARK: compose "string or list or map" shapes

    static func list(_ v: Any?) -> [String] {
        if let a = v as? [Any] { return a.map { "\($0)" } }
        return v.map { ["\($0)"] } ?? []
    }

    static func words(_ v: Any?) -> [String] {
        v is String ? shellSplit(v as! String) : list(v)
    }

    /// `environment`/`labels`/`args`: a map, or a list of `K=V` (`K` alone inherits from our environment).
    static func pairs(_ v: Any?) -> [(String, String?)] {
        if let m = v as? Dict {
            return m.keys.sorted().map { k in (k, (m[k]).flatMap { $0 is NSNull ? nil : "\($0)" }) }
        }
        return list(v).map { e in
            guard let i = e.firstIndex(of: "=") else { return (e, ProcessInfo.processInfo.environment[e]) }
            return (String(e[..<i]), String(e[e.index(after: i)...]))
        }
    }
}

func warn(_ s: String) { FileHandle.standardError.write(Data("mdocker: \(s)\n".utf8)) }

func sanitize(_ s: String) -> String {
    String(s.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" })
}

func shellSplit(_ s: String) -> [String] {
    var out: [String] = []
    var cur = "", quote: Character?, started = false
    for c in s {
        if let q = quote {
            if c == q { quote = nil } else { cur.append(c) }
        } else if c == "\"" || c == "'" {
            quote = c; started = true
        } else if c.isWhitespace {
            if started { out.append(cur); cur = ""; started = false }
        } else {
            cur.append(c); started = true
        }
    }
    if started { out.append(cur) }
    return out
}

func parseEnv(_ text: String) -> [String: String] {
    var out: [String: String] = [:]
    for line in text.split(whereSeparator: \.isNewline) {
        let l = line.trimmingCharacters(in: .whitespaces)
        guard !l.hasPrefix("#"), let i = l.firstIndex(of: "=") else { continue }
        let v = l[l.index(after: i)...].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        out[String(l[..<i])] = v
    }
    return out
}

/// `$VAR`, `${VAR}`, `${VAR:-default}`, and `$$` (a literal `$`).
func interpolate(_ text: String, env: [String: String]) -> String {
    let re = try! NSRegularExpression(pattern: #"\$(?:(\$)|\{(\w+)(?::?-([^}]*))?\}|(\w+))"#)
    var out = text
    for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
        func group(_ i: Int) -> String? { Range(m.range(at: i), in: text).map { String(text[$0]) } }
        let value: String
        if group(1) != nil { value = "$" }
        else if let name = group(2) ?? group(4) {
            let v = env[name]
            value = (v?.isEmpty == false ? v : nil) ?? group(3) ?? ""
        } else { continue }
        out.replaceSubrange(Range(m.range, in: out)!, with: value)
    }
    return out
}
