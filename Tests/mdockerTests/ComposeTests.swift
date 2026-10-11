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
    #expect(p.volumes == ["cache"])
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
