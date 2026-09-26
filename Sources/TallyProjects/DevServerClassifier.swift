import Foundation
import TallyCore

/// Decides which processes are dev tools or servers, and what kind.
enum DevServerClassifier {
    private static let shells: Set<String> = [
        "zsh", "bash", "sh", "fish", "dash", "tcsh", "csh", "ksh", "nu", "xonsh", "elvish", "login", "pwsh",
    ]

    private static let editors: Set<String> = [
        "vim", "nvim", "vi", "view", "vimdiff", "emacs", "emacsclient", "nano", "pico", "micro", "hx", "helix", "kak", "ed",
        "code", "code-insiders", "cursor", "windsurf", "zed", "subl", "sublime_text", "mate", "bbedit", "nova",
        "idea", "webstorm", "pycharm", "goland", "rubymine", "phpstorm", "rider", "clion", "fleet", "xed",
    ]

    /// AI coding agents behave like editors: interactive tools that happen to run in the project folder.
    private static let agents: Set<String> = [
        "claude", "codex", "gemini", "aider", "opencode", "cursor-agent", "amp", "goose", "crush", "copilot", "qwen", "kiro-cli",
    ]

    private static let agentPackages = [
        "@anthropic-ai/claude-code", "@openai/codex", "@google/gemini-cli", "@github/copilot", "opencode-ai", "@sourcegraph/amp",
        "@qwen-code/", "@charmland/crush",
    ]

    private static let tools: Set<String> = [
        "tmux", "screen", "zellij", "ssh", "ssh-agent", "mosh-client", "less", "more", "man", "top", "htop", "btop", "watch",
        "sudo", "su", "caffeinate", "sleep", "tail", "cat", "lsof", "git", "gh", "script", "fzf", "lazygit", "tig", "ranger",
        "yazi", "nnn", "mc", "afplay", "ps", "grep", "rg", "find", "make", "xargs", "env", "nohup", "time", "open",
    ]

    /// Where a parent-chain walk stops and treats the process as started by the user.
    private static let terminals: Set<String> = [
        "terminal", "iterm2", "ghostty", "wezterm-gui", "alacritty", "kitty", "stable", "warp", "hyper", "tabby", "rio",
        "tmux", "screen", "zellij", "sshd", "launchd",
    ]

    /// Editor plumbing that runs on a language runtime inside the project: language servers and formatters.
    private static let helperPatterns = [
        "tsserver", "typingsinstaller", "language-server", "languageserver", "langserver", "lsp-proxy", "ruby-lsp", "pylsp",
        "sourcekit-lsp", "gopls", "rust-analyzer", "pyright", "basedpyright", "pylance", "jedi-language", "eslint_d",
        "prettierd", "copilot-language", "intelephense", "solargraph", "elixir-ls",
    ]

    private static let systemPrefixes = [
        "/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/bin/", "/Library/Apple/", "/Library/Developer/PrivateFrameworks/",
        "/Library/PrivilegedHelperTools/", "/private/var/db/",
    ]

    /// Lowercased executable name without a login-shell dash.
    static func normalizedName(name: String, executablePath: String?) -> String {
        let base = executablePath.map { ($0 as NSString).lastPathComponent } ?? name
        let lowered = (base.isEmpty ? name : base).lowercased()
        return lowered.hasPrefix("-") ? String(lowered.dropFirst()) : lowered
    }

    /// A cheap first pass on the name and path alone, so most processes cost no system calls.
    static func isObviouslyExcluded(normalizedName name: String, executablePath: String?) -> Bool {
        if shells.contains(name) || editors.contains(name) || agents.contains(name) || tools.contains(name) { return true }
        guard let path = executablePath else { return false }
        if systemPrefixes.contains(where: { path.hasPrefix($0) }) { return true }
        if isInsideBundle(path) && !isAllowedBundledRuntime(path: path, name: name) { return true }
        return false
    }

    /// True for helpers and agents recognised only from their arguments, such as `node …/claude-code/cli.js`.
    static func isExcludedByArguments(_ arguments: [String]) -> Bool {
        guard arguments.count > 1 else { return false }
        let joined = arguments.joined(separator: " ").lowercased()
        if agentPackages.contains(where: { joined.contains($0) }) { return true }
        if helperPatterns.contains(where: { joined.contains($0) }) { return true }
        if let script = scriptArgument(arguments) {
            let scriptName = (script as NSString).lastPathComponent.lowercased()
            if agents.contains(scriptName) || editors.contains(scriptName) { return true }
        }
        return false
    }

    static func isShell(_ name: String) -> Bool { shells.contains(name) }

    static func isTerminalBoundary(_ name: String) -> Bool { shells.contains(name) || terminals.contains(name) }

    /// Editors, agents and apps that start helpers of their own.
    static func isHelperOwner(normalizedName name: String, executablePath: String?) -> Bool {
        if editors.contains(name) || agents.contains(name) { return true }
        if let path = executablePath, isInsideBundle(path), !isAllowedBundledRuntime(path: path, name: name) { return true }
        return false
    }

    /// The runtime behind a process, from its executable name and arguments.
    static func kind(normalizedName name: String, executablePath: String?, arguments: [String]) -> DevServerKind? {
        if let direct = kind(forName: name) { return direct }
        if let path = executablePath {
            if path.contains("/go-build") { return .go }
            if path.contains("/node_modules/") { return .node }
            if path.contains("/.venv/") || path.contains("/venv/") { return .python }
        }
        if let first = arguments.first {
            let invoked = (first as NSString).lastPathComponent.lowercased()
            if invoked != name, let fromArgument = kind(forName: invoked) { return fromArgument }
        }
        return nil
    }

    private static func kind(forName name: String) -> DevServerKind? {
        switch name {
        case "node", "nodejs", "npm", "npx", "pnpm", "yarn", "tsx", "ts-node", "nodemon", "vite", "next", "nuxt", "astro", "wrangler":
            return .node
        case "bun", "bunx":
            return .bun
        case "deno":
            return .deno
        case "uvicorn", "gunicorn", "hypercorn", "daphne", "celery", "flask", "streamlit", "uv", "poetry", "pipenv", "jupyter",
             "jupyter-lab", "jupyter-notebook", "jupyter-server":
            return .python
        case "rails", "puma", "unicorn", "sidekiq", "bundle", "rake", "foreman", "jekyll", "thin", "falcon":
            return .ruby
        case "go", "air", "gow":
            return .go
        case "cargo", "trunk":
            return .rust
        case "java", "gradle", "gradlew", "mvn", "kotlin", "sbt", "lein", "clojure":
            return .java
        case "frankenphp", "artisan", "composer":
            return .php
        case "beam.smp", "beam", "erl", "erlexec", "elixir", "iex", "mix":
            return .elixir
        case "dotnet":
            return .dotnet
        case "docker", "docker-compose", "com.docker.cli", "podman", "podman-compose":
            return .docker
        default:
            break
        }
        if name.hasPrefix("python") || name.hasPrefix("pypy") { return .python }
        if name.hasPrefix("ruby") { return .ruby }
        if name.hasPrefix("php") { return .php }
        if name.hasPrefix("cargo-") { return .rust }
        if name.hasPrefix("dotnet-") { return .dotnet }
        return nil
    }

    /// A kind for an executable built inside the project folder, from where it sits and what the project uses.
    static func kindForBinary(atPath path: String, inProject root: String, hasFile: (String) -> Bool) -> DevServerKind? {
        let relative = String(path.dropFirst(root.count))
        if relative.contains("/node_modules/") { return .node }
        if relative.contains("/target/debug/") || relative.contains("/target/release/") { return .rust }
        if hasFile("go.mod") { return .go }
        if hasFile("Cargo.toml") { return .rust }
        return nil
    }

    /// The first argument after the interpreter that is not a flag: usually the script being run.
    static func scriptArgument(_ arguments: [String]) -> String? {
        var skipNext = false
        for argument in arguments.dropFirst() {
            if skipNext { skipNext = false; continue }
            if argument == "-m" || argument == "-e" || argument == "-c" || argument == "--eval" { return nil }
            if argument == "-r" || argument == "--require" || argument == "--import" || argument == "--loader" {
                skipNext = true
                continue
            }
            if argument.hasPrefix("-") { continue }
            return argument
        }
        return nil
    }

    private static func isInsideBundle(_ path: String) -> Bool {
        path.contains(".app/") || path.contains(".xpc/") || path.contains(".appex/") || path.contains(".bundle/")
    }

    /// Python from Xcode or python.org lives in a Python.app, and Docker's CLI inside Docker.app.
    private static func isAllowedBundledRuntime(path: String, name: String) -> Bool {
        let components = path.split(separator: "/")
        if let lastBundle = components.last(where: { $0.hasSuffix(".app") || $0.hasSuffix(".xpc") || $0.hasSuffix(".appex") }) {
            if lastBundle == "Python.app" { return true }
            if path.contains("/Docker.app/"), kind(forName: name) == .docker { return true }
        }
        return false
    }
}
