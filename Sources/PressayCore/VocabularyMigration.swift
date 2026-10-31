import Foundation

/// Retires the old bundled dictionary without deleting user-added vocabulary.
package enum VocabularyMigration {
    private static let lastBundledSource = """
    # Communication and AI agents
    Slack
    Kimi Code <= kimi code
    Kimi <= kimmy, akimi
    Claude Code <= claude code, cloud code
    Claude
    Anthropic <= entropic
    Codex
    OpenAI <= open ai
    ChatGPT <= chat gpt
    Wispr Flow <= whisper flow, whisperflow
    Pressay
    Orukeet
    SonarCloud <= soonercloud, sooner cloud
    RunPod <= rumpod
    TL;DR <= tldr

    # Apple development
    SwiftUI <= swift ui
    SwiftData <= swift data
    Core ML <= core ml, coreml
    FluidAudio <= fluid audio
    WhisperKit <= whisper kit
    macOS <= mac os
    Apple Silicon

    # Developer workflow
    GitHub <= git hub
    GitLab <= git lab
    VS Code <= vs code, v s code
    Node.js <= node js, node dot js
    Next.js <= next js, next dot js
    PostgreSQL <= postgres sql
    Docker
    Markdown
    PR <= p r
    API <= a p i
    JSON <= j s o n
    .env <= dot env
    package.json <= package json
    CLAUDE.md <= claude md, cloud md, claudemd, cloudmd
    AGENTS.md <= agents md
    """

    package static let bundledSources: [String] = [
        lastBundledSource,
        """
        SwiftUI
        SwiftData
        Core ML <= coreml, core ml
        WhisperKit <= whisper kit
        FluidAudio <= fluid audio
        """,
        """
        SwiftUI <= swift ui
        SwiftData <= swift data
        Core ML <= coreml, core ml
        WhisperKit <= whisper kit
        FluidAudio <= fluid audio
        macOS <= mac os
        """,
        """
        # Communication and AI agents
        Slack
        DM <= d m
        AI
        LLM <= l l m
        OpenAI <= open ai
        ChatGPT <= chat gpt
        Codex
        Claude
        Anthropic
        GitHub Copilot <= git hub copilot
        MCP <= m c p
        RAG <= r a g

        # Source control, editors, and developer workflow
        GitHub <= git hub
        GitLab <= git lab
        Bitbucket <= bit bucket
        VS Code <= vs code, v s code, visual studio code
        PR <= p r
        CI/CD <= ci cd, c i c d
        DevOps <= dev ops
        Homebrew <= home brew
        API <= a p i
        SDK <= s d k
        CLI <= c l i
        UI <= u i
        UX <= u x
        URL <= u r l
        URI <= u r i
        HTTP <= h t t p
        HTTPS <= h t t p s

        # Apple development
        Swift
        SwiftUI <= swift ui
        SwiftData <= swift data
        AppKit <= app kit
        UIKit <= ui kit
        Xcode <= x code
        XCTest <= x c test, x test
        macOS <= mac os, mac o s
        iOS <= i os, i o s
        Core ML <= core ml, coreml
        WhisperKit <= whisper kit
        FluidAudio <= fluid audio
        Apple Silicon
        MLX <= m l x
        MainActor <= main actor
        ObservableObject <= observable object
        Codable
        Sendable
        AVAudioEngine <= av audio engine, a v audio engine
        AVAudioConverter <= av audio converter, a v audio converter
        Swift Package Manager
        SPM <= s p m

        # Languages, formats, and web tooling
        JavaScript <= java script
        TypeScript <= type script
        Node.js <= node js, node dot js
        Next.js <= next js, next dot js
        Python
        PyTorch <= py torch
        Kotlin
        C++ <= c plus plus
        C# <= c sharp
        HTML <= h t m l
        CSS <= c s s
        JSON <= j s o n
        YAML <= y a m l
        XML <= x m l
        Markdown
        Bash
        Zsh <= z shell
        npm <= n p m
        pnpm <= p n p m
        Vite
        ESLint <= e s lint
        Tailwind CSS <= tailwind css
        GraphQL <= graph ql, graph q l
        REST API <= rest api
        WebSocket <= web socket
        OAuth <= o auth
        JWT <= j w t
        OpenAPI <= open api
        FastAPI <= fast api

        # Data and infrastructure
        PostgreSQL <= postgres sql
        Postgres
        MySQL <= my sql
        SQLite <= sql lite, sequel lite
        MongoDB <= mongo db
        Redis
        Supabase <= supa base
        Firebase <= fire base
        Docker
        Kubernetes
        Terraform <= terra form
        AWS <= a w s
        GCP <= g c p
        Azure
        Cloudflare <= cloud flare
        Vercel <= ver sell
        Netlify

        # Commonly dictated identifiers and files
        camelCase <= camel case
        PascalCase <= pascal case
        snake_case <= snake case
        kebab-case <= kebab case
        .env <= dot env
        .gitignore <= git ignore
        package.json <= package json
        tsconfig.json <= ts config json
        """,
    ]

    /// Remove recognizable stock content; custom sections and edited entries stay intact.
    /// Call once per installation so subsequently added user entries are never migrated.
    package static func manualSource(from stored: String?) -> String {
        guard let stored else { return "" }
        let source = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        for bundled in bundledSources.sorted(by: { $0.count > $1.count }) {
            if source == bundled { return "" }
            if source.hasPrefix(bundled + "\n") {
                return String(source.dropFirst(bundled.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let stockLines = Set(bundledSources.flatMap { $0.components(separatedBy: "\n") })
        let stockHeaders = stockLines.filter { $0.hasPrefix("#") }
        // A standalone manually entered term can equal a former default. Only remove
        // stock lines inside recognizable bundled sections, never arbitrary user lists.
        guard let first = source.components(separatedBy: "\n").first,
              stockHeaders.contains(first) else { return stored }
        var result: [String] = []
        var header: String?
        var stockSection = false
        for line in source.components(separatedBy: "\n") {
            if line.hasPrefix("#") {
                header = line
                stockSection = stockHeaders.contains(line)
                continue
            }
            if stockSection && (line.isEmpty || stockLines.contains(line)) { continue }
            if let pending = header {
                result.append(pending)
                header = nil
            }
            result.append(line)
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
