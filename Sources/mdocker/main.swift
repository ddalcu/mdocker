import Foundation

/// docker verbs that `container` spells differently; everything else passes through unchanged.
let rewrites: [String: [String]] = [
    "ps": ["ls"], "images": ["image", "ls"], "pull": ["image", "pull"], "push": ["image", "push"],
    "tag": ["image", "tag"], "rmi": ["image", "rm"], "save": ["image", "save"], "load": ["image", "load"],
    "login": ["registry", "login"], "logout": ["registry", "logout"],
    "info": ["system", "status"], "version": ["system", "version"],
]

let usage = """
usage: mdocker <command> [args]
       mdocker compose [-f file] [-p name] up|down|ps|logs|exec [args]

Docker-style front end for Apple's `container`. Commands: run ps images pull push
tag rmi build exec logs stop kill rm cp inspect stats network volume login ...
"""

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first, !["-h", "--help", "help"].contains(cmd) else {
    print(usage)
    exit(args.isEmpty ? 1 : 0)
}
let rest = Array(args.dropFirst())

if cmd == "compose" { exit(Compose.main(rest)) }

if !["system", "info", "version"].contains(cmd) { Engine.ensureStarted() }

// docker's `logs --tail N` is `-n N` here.
let fixed = cmd == "logs" ? rest.map { $0 == "--tail" ? "-n" : $0.replacingOccurrences(of: "--tail=", with: "-n") } : rest
if cmd == "run" || cmd == "create" { Engine.makeBindDirs(fixed) }
Engine.exec((rewrites[cmd] ?? [cmd]) + fixed)
