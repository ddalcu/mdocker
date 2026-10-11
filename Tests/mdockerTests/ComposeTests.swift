import Foundation
import Testing
@testable import mdocker

private func project(_ yaml: String, env: [String: String] = [:]) throws -> Project {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("compose.yaml")
    try yaml.write(to: file, atomically: true, encoding: .utf8)
    return try Project.load(file: file.path, name: "demo", env: env)
}

@Test func ordersByDependsOnAndPullsInDependencies() throws {
    let p = try project("""
    services:
      app: {image: a, depends_on: [db, cache]}
      db: {image: b}
      cache: {image: c, depends_on: {db: {condition: service_started}}}
      other: {image: d}
    """)
    #expect(try p.order([]) == ["db", "cache", "app", "other"])
    #expect(try p.order(["app"]) == ["db", "cache", "app"])
}

@Test func rejectsCyclesAndUnknownServices() throws {
    let p = try project("services: {a: {image: x, depends_on: [b]}, b: {image: x, depends_on: [a]}}")
    #expect(throws: ComposeError.self) { try p.order([]) }
    #expect(throws: ComposeError.self) { try p.order(["nope"]) }
}

@Test func translatesRunArgs() throws {
    let p = try project("""
    services:
      web:
        image: nginx
        entrypoint: ["/entry.sh", "--x"]
        command: serve "two words"
        environment: {A: "1", B: 2}
        ports: ["8080:80"]
        volumes: ["./data:/data:ro", "cache:/cache"]
        working_dir: /srv
    volumes: {cache: {}}
    """)
    let a = p.runArgs("web")
    #expect(a.contains("demo-web") && a.contains("mdocker.service=web"))
    #expect(a.joined(separator: " ").contains("-e A=1 -e B=2 -p 8080:80"))
    #expect(a.contains("\(p.dir.path)/data:/data:ro"))
    #expect(a.contains("demo_cache:/cache"))
    #expect(a.joined(separator: " ").contains("--entrypoint /entry.sh"))
    #expect(Array(a.suffix(4)) == ["nginx", "--x", "serve", "two words"])
    #expect(p.volumes.keys.sorted() == ["cache"])
}

@Test func hashChangesWithConfig() throws {
    func hash(_ image: String) throws -> String {
        try project("services: {s: {image: \(image)}}").runArgs("s").first { $0.hasPrefix("mdocker.hash=") }!
    }
    #expect(try hash("a") == hash("a"))
    #expect(try hash("a") != hash("b"))
}

@Test func interpolatesAndSplits() {
    #expect(interpolate("${A} ${B:-dflt} $A $$ ${C:-}", env: ["A": "x"]) == "x dflt x $ ")
    #expect(shellSplit(#"sh -c "echo hi" 'a b'"#) == ["sh", "-c", "echo hi", "a b"])
    #expect(parseEnv("# c\nK=\"v\"\nJ=1") == ["K": "v", "J": "1"])
}

@Test func translatesLongFormVolumesAndTmpfs() throws {
    let p = try project("""
    services:
      s:
        image: x
        volumes:
          - {type: bind, source: ./src, target: /src, read_only: true}
          - {type: volume, source: data, target: /data}
          - {type: volume, target: /anon}
          - {type: tmpfs, target: /scratch}
        tmpfs: /run
        shm_size: 64m
    volumes: {data: {}}
    """)
    let a = p.runArgs("s").joined(separator: " ")
    #expect(a.contains("-v \(p.dir.path)/src:/src:ro"))
    #expect(a.contains("-v demo_data:/data"))
    #expect(a.contains("-v /anon"))
    #expect(a.contains("--tmpfs /scratch") && a.contains("--tmpfs /run"))
    #expect(a.contains("--shm-size 64m"))
}

@Test func topLevelVolumeNamingAndExternal() throws {
    let p = try project("""
    services: {s: {image: x, volumes: ["ext:/e", "named:/n", "plain:/p"]}}
    volumes:
      ext: {external: true}
      named: {name: shared-name}
      plain:
    """)
    #expect(p.volumeName("ext") == "ext" && p.isExternal("ext"))
    #expect(p.volumeName("named") == "shared-name" && !p.isExternal("named"))
    #expect(p.volumeName("plain") == "demo_plain")
    let a = p.runArgs("s")
    #expect(a.contains("ext:/e") && a.contains("shared-name:/n") && a.contains("demo_plain:/p"))
}
