import Foundation

/// AI tool layouts, based on the directory structure of the installed versions.
/// Anything not listed explicitly as a cache or log is treated as user data.
enum AIToolAdapters {
    static func all() -> [any ToolAdapter] {
        [claudeCode, codex, cursor, claudeDesktop, ollama, lmStudio, huggingFace, gemini]
    }

    private static let electronCacheDirs: [(String, String)] = [
        ("Cache", "웹 콘텐츠 캐시"), ("Code Cache", "스크립트 코드 캐시"), ("GPUCache", "GPU 셰이더 캐시"),
        ("CachedData", "컴파일된 코드 캐시"), ("CachedExtensionVSIXs", "확장 설치 파일 캐시"),
        ("CachedProfilesData", "프로필 캐시"), ("DawnGraphiteCache", "그래픽 캐시"),
        ("DawnWebGPUCache", "WebGPU 캐시"), ("GraphiteDawnCache", "그래픽 캐시"), ("GPUPersistentCache", "GPU 캐시"),
    ]

    private static func electronItems(base: String, appName: String) -> [DirectoryToolAdapter.Item] {
        electronCacheDirs.map { dir, title in
            DirectoryToolAdapter.Item(relativePath: "\(base)/\(dir)", title: "\(appName) \(title)", category: .aiCache,
                                      risk: .safe, reason: "Electron이 자동으로 다시 만드는 캐시",
                                      impact: "다음 실행 시 캐시를 다시 만들며 잠시 느릴 수 있습니다.")
        }
    }

    static let claudeCode = DirectoryToolAdapter(
        id: "claude-code", name: "Claude Code", symbol: "terminal", kind: .ai,
        detectPaths: [".claude", ".claude.json"], appPaths: [],
        guards: [.process("claude", "Claude Code"), .commandLine("@anthropic-ai/claude-code", "Claude Code")],
        items: [
            .init(relativePath: "Library/Caches/claude-cli-nodejs", title: "MCP 서버 로그", category: .aiLogs,
                  risk: .safe, reason: "프로젝트별 MCP 로그 — 대화 기록 아님",
                  impact: "과거 MCP 로그가 사라집니다. 대화와 설정에는 영향 없음."),
            .init(relativePath: ".claude/shell-snapshots", title: "셸 스냅샷", category: .aiCache, risk: .review,
                  reason: "세션 시작 시 다시 만들어지는 셸 환경 스냅샷", impact: "다음 세션 시작 시 다시 만들어집니다."),
            .init(relativePath: ".claude/paste-cache", title: "붙여넣기 캐시", category: .aiCache, risk: .review,
                  reason: "긴 붙여넣기 내용 캐시 — 이전 세션을 다시 열 때 참조될 수 있음",
                  impact: "이전 세션에서 붙여넣은 큰 텍스트를 다시 볼 수 없을 수 있습니다."),
            .init(relativePath: ".claude/cache", title: "메타데이터 캐시", category: .aiCache, risk: .review,
                  reason: "변경 기록·모델 목록 캐시", impact: "필요할 때 다시 받아옵니다."),
            .init(relativePath: ".cache/claude/staging", title: "업데이트 스테이징", category: .aiCache, risk: .review,
                  reason: "업데이트 설치용 임시 파일", impact: "다음 업데이트 시 다시 받습니다."),
        ],
        protectedItems: [
            .init(relativePath: ".claude/projects", title: "프로젝트 대화 기록", role: .history),
            .init(relativePath: ".claude/sessions", title: "세션", role: .history),
            .init(relativePath: ".claude/history.jsonl", title: "입력 기록", role: .history),
            .init(relativePath: ".claude/file-history", title: "파일 체크포인트", role: .history),
            .init(relativePath: ".claude/plugins", title: "플러그인", role: .settings),
            .init(relativePath: ".claude/skills", title: "스킬", role: .settings),
            .init(relativePath: ".claude/settings.json", title: "설정", role: .settings),
            .init(relativePath: ".claude.json", title: "전역 설정·인증 상태", role: .credentials),
            .init(relativePath: ".claude/backups", title: "설정 백업", role: .settings),
        ],
        notes: ["대화 기록, 세션, 메모리, 설정, 플러그인은 보호되며 정리 대상에 포함되지 않습니다."])

    static let codex = DirectoryToolAdapter(
        id: "codex", name: "Codex", symbol: "chevron.left.forwardslash.chevron.right", kind: .ai,
        detectPaths: [".codex"], appPaths: ["/Applications/Codex.app"],
        guards: [.process("codex", "Codex CLI"), .app("com.openai.codex", "Codex")],
        items: [
            .init(relativePath: "Library/Caches/com.openai.codex", title: "앱 캐시", category: .aiCache, risk: .safe,
                  reason: "Codex 앱의 재생성 가능한 캐시", impact: "다음 실행 시 다시 만들어집니다."),
            .init(relativePath: ".codex/cache", title: "CLI 캐시", category: .aiCache, risk: .review,
                  reason: "Codex CLI 캐시", impact: "필요할 때 다시 받아옵니다."),
            .init(relativePath: ".codex/.tmp", title: "임시 파일", category: .aiCache, risk: .review,
                  reason: "작업 중 임시 파일", impact: "실행 중이 아니면 영향 없음."),
            .init(relativePath: ".codex/tmp", title: "임시 파일", category: .aiCache, risk: .review,
                  reason: "작업 중 임시 파일", impact: "실행 중이 아니면 영향 없음."),
            .init(relativePath: ".cache/codex-runtimes", title: "런타임 다운로드", category: .aiCache, risk: .review,
                  reason: "다시 내려받을 수 있는 런타임", impact: "다음 실행 시 다시 내려받습니다."),
        ],
        protectedItems: [
            .init(relativePath: ".codex/sessions", title: "세션 기록", role: .history),
            .init(relativePath: ".codex/auth.json", title: "인증 정보", role: .credentials),
            .init(relativePath: ".codex/config.toml", title: "설정", role: .settings),
            .init(relativePath: ".codex/worktrees", title: "작업 트리", role: .data),
            .init(relativePath: ".codex/generated_images", title: "생성 이미지", role: .data),
            .init(relativePath: ".codex/attachments", title: "첨부 파일", role: .data),
            .init(relativePath: ".codex/skills", title: "스킬", role: .settings),
        ],
        notes: ["세션, 인증, 메모리 데이터베이스(*.sqlite), 작업 트리는 보호됩니다."])

    static let cursor = DirectoryToolAdapter(
        id: "cursor", name: "Cursor", symbol: "cursorarrow.rays", kind: .ai,
        detectPaths: ["Library/Application Support/Cursor"], appPaths: ["/Applications/Cursor.app"],
        guards: [.app("com.todesktop.230313mzl4w4u92", "Cursor"), .process("cursor", "Cursor")],
        items: electronItems(base: "Library/Application Support/Cursor", appName: "Cursor") + [
            .init(relativePath: "Library/Application Support/Cursor/logs", title: "Cursor 로그", category: .aiLogs,
                  risk: .safe, reason: "진단용 로그", impact: "과거 로그가 사라집니다."),
            .init(relativePath: "Library/Caches/com.todesktop.230313mzl4w4u92", title: "Cursor 앱 캐시",
                  category: .aiCache, risk: .safe, reason: "재생성 가능한 캐시", impact: "다시 만들어집니다."),
            .init(relativePath: "Library/Caches/com.todesktop.230313mzl4w4u92.ShipIt", title: "Cursor 업데이트 잔여 파일",
                  category: .aiCache, risk: .safe, reason: "설치가 끝난 업데이트 다운로드", impact: "영향 없음."),
            .init(relativePath: "Library/Caches/cursor-compile-cache", title: "Cursor 컴파일 캐시",
                  category: .aiCache, risk: .safe, reason: "재생성 가능한 캐시", impact: "다시 만들어집니다."),
        ],
        protectedItems: [
            .init(relativePath: "Library/Application Support/Cursor/User", title: "사용자 설정·채팅 기록", role: .history),
            .init(relativePath: "Library/Application Support/Cursor/Backups", title: "편집 백업", role: .data),
            .init(relativePath: "Library/Application Support/Cursor/AgentStores", title: "에이전트 데이터", role: .data),
            .init(relativePath: ".cursor", title: "확장 및 설정", role: .settings),
        ],
        notes: ["Cursor가 실행 중이면 캐시 정리를 건너뜁니다."])

    static let claudeDesktop = DirectoryToolAdapter(
        id: "claude-desktop", name: "Claude", symbol: "bubble.left.and.text.bubble.right", kind: .ai,
        detectPaths: ["Library/Application Support/Claude"], appPaths: ["/Applications/Claude.app"],
        guards: [.app("com.anthropic.claudefordesktop", "Claude")],
        items: electronItems(base: "Library/Application Support/Claude", appName: "Claude") + [
            .init(relativePath: "Library/Caches/com.anthropic.claudefordesktop", title: "Claude 앱 캐시",
                  category: .aiCache, risk: .safe, reason: "재생성 가능한 캐시", impact: "다시 만들어집니다."),
            .init(relativePath: "Library/Caches/com.anthropic.claudefordesktop.ShipIt", title: "Claude 업데이트 잔여 파일",
                  category: .aiCache, risk: .safe, reason: "설치가 끝난 업데이트 다운로드", impact: "영향 없음."),
            .init(relativePath: "Library/Logs/Claude", title: "Claude 로그", category: .aiLogs, risk: .review,
                  reason: "문제 진단용 로그", impact: "과거 로그가 사라집니다."),
        ],
        protectedItems: [
            .init(relativePath: "Library/Application Support/Claude/claude-code-sessions", title: "Claude Code 세션", role: .history),
            .init(relativePath: "Library/Application Support/Claude/local-agent-mode-sessions", title: "에이전트 세션", role: .history),
            .init(relativePath: "Library/Application Support/Claude/vm_bundles", title: "VM 번들", role: .data),
            .init(relativePath: "Library/Application Support/Claude/IndexedDB", title: "앱 데이터", role: .data),
        ],
        notes: ["세션, 설정, VM 번들은 보호됩니다. Claude가 실행 중이면 캐시 정리를 건너뜁니다."])

    static let ollama = DirectoryToolAdapter(
        id: "ollama", name: "Ollama", symbol: "brain.head.profile", kind: .ai,
        detectPaths: [".ollama"], appPaths: ["/Applications/Ollama.app"],
        guards: [.process("ollama", "Ollama")],
        items: [
            .init(relativePath: ".ollama/logs", title: "Ollama 로그", category: .aiLogs, risk: .safe,
                  reason: "서버 로그", impact: "과거 로그가 사라집니다."),
        ],
        protectedItems: [],
        notes: ["모델은 캐시가 아닙니다. 모델 삭제는 `ollama rm`으로만 수행하며 개별 확인이 필요합니다."],
        extra: { ctx, report in await OllamaModels.scan(ctx, into: &report) })

    static let lmStudio = DirectoryToolAdapter(
        id: "lm-studio", name: "LM Studio", symbol: "cpu", kind: .ai,
        detectPaths: [".lmstudio", ".cache/lm-studio"], appPaths: ["/Applications/LM Studio.app"],
        guards: [.app("ai.elementlabs.lmstudio", "LM Studio"), .process("lm studio", "LM Studio"), .process("lms", "lms")],
        items: [], protectedItems: [],
        notes: ["다운로드한 모델은 개별 선택 후 휴지통으로만 이동합니다."],
        extra: { ctx, report in LocalModelDirectories.scanLMStudio(ctx, into: &report) })

    static let huggingFace = DirectoryToolAdapter(
        id: "huggingface", name: "Hugging Face 캐시", symbol: "face.smiling", kind: .ai,
        detectPaths: [".cache/huggingface"], appPaths: [],
        guards: [.commandLine("huggingface", "Hugging Face 프로세스"), .commandLine("transformers", "Transformers")],
        items: [
            .init(relativePath: ".cache/huggingface/xet", title: "Xet 청크 캐시", category: .aiCache, risk: .review,
                  reason: "다운로드 가속용 청크 캐시", impact: "다음 다운로드가 느려질 수 있습니다."),
        ],
        protectedItems: [],
        notes: ["hub 아래 모델과 데이터셋은 사용자가 내려받은 데이터로 취급합니다."],
        extra: { ctx, report in LocalModelDirectories.scanHuggingFace(ctx, into: &report) })

    static let gemini = DirectoryToolAdapter(
        id: "gemini-cli", name: "Gemini CLI", symbol: "sparkle", kind: .ai,
        detectPaths: [".gemini"], appPaths: [],
        guards: [.commandLine("gemini", "Gemini CLI")],
        items: [],
        protectedItems: [.init(relativePath: ".gemini", title: "설정 및 기록", role: .history)],
        notes: ["Gemini CLI 데이터는 기록과 설정만 포함하므로 분석만 제공합니다."])
}

/// Ollama stores models as content-addressed blobs referenced by manifests, so a
/// model's size is the sum of its layers. Deleting blobs directly would corrupt
/// other models that share layers; removal goes through `ollama rm`.
enum OllamaModels {
    struct Manifest: Decodable {
        struct Layer: Decodable { let size: Int64; let digest: String }
        let layers: [Layer]?
        let config: Layer?
    }

    static var modelNamePattern: Regex<Substring> { /^[A-Za-z0-9._\-\/]+:[A-Za-z0-9._\-]+$/ }

    static func scan(_ ctx: ScanContext, into report: inout ToolReport) async {
        let manifests = ctx.url(".ollama/models/manifests")
        guard ctx.exists(manifests) else { return }
        if let loc = ctx.location(ctx.url(".ollama/models"), title: "모델 저장소", role: .models, protected: true,
                                  note: "모델은 개별 확인 후 ollama rm으로 삭제") {
            report.locations.append(loc)
        }
        var loaded: Set<String> = []
        if let ps = try? await ctx.commandRunner.run(.ollama, ["ps"], timeout: 10), ps.succeeded {
            for line in ps.stdout.split(separator: "\n").dropFirst() {
                if let name = line.split(separator: " ").first { loaded.insert(String(name)) }
            }
        }
        let cliAvailable = ctx.commandRunner.locate(.ollama) != nil

        var models: [(name: String, size: Int64, modified: Date)] = []
        try? FTSWalker(root: manifests.path).walk { entry in
            guard entry.kind == .file, let st = entry.stat,
                  let data = FileManager.default.contents(atPath: entry.path),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return .continue }
            let rel = PathUtilities.components(String(entry.path.dropFirst(manifests.path.count)))
            // registry.ollama.ai/library/llama3/8b → llama3:8b ; other namespaces keep their prefix.
            guard rel.count >= 3 else { return .continue }
            let tag = rel[rel.count - 1]
            let model = rel[rel.count - 2]
            let namespace = rel[rel.count - 3]
            var name = namespace == "library" ? "\(model):\(tag)" : "\(namespace)/\(model):\(tag)"
            if rel.count > 3, rel[0] != "registry.ollama.ai" { name = "\(rel[0])/\(name)" }
            let size = (manifest.layers ?? []).reduce(manifest.config?.size ?? 0) { $0 + $1.size }
            models.append((name, size, Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))))
            return .continue
        }
        for model in models.sorted(by: { $0.size > $1.size }) {
            var risk = RiskLevel.manual
            var reason = "다운로드한 모델 — 다시 받으려면 시간이 오래 걸립니다"
            if !cliAvailable { risk = .blocked; reason = "ollama CLI를 찾지 못해 안전하게 삭제할 수 없음" }
            if loaded.contains(model.name) { risk = .blocked; reason = "현재 메모리에 로드되어 사용 중" }
            if model.name.wholeMatch(of: modelNamePattern) == nil { risk = .blocked; reason = "예상하지 못한 모델 이름" }
            report.candidates.append(CleanupCandidate(
                id: "ollama-model:\(model.name)", title: model.name, subtitle: "ollama rm \(model.name)",
                category: .aiModels, ruleID: "ai.ollama.model", risk: risk, riskReason: reason,
                impact: "모델이 삭제됩니다. 다시 사용하려면 `ollama pull`로 내려받아야 합니다. 다른 모델과 공유하는 레이어는 유지됩니다.",
                regenerable: false,
                size: SizeInfo(logical: model.size, allocated: model.size, fileCount: 1, newestModification: model.modified),
                lastModified: model.modified,
                target: .command(TrustedCommand(tool: .ollama, arguments: ["rm", model.name])),
                guards: [], preferredMethod: .permanent, allowsPermanentRemoval: true,
                warning: "공유 레이어가 있으면 실제 확보 공간은 표시보다 작을 수 있습니다."))
        }
    }
}

enum LocalModelDirectories {
    static func scanLMStudio(_ ctx: ScanContext, into report: inout ToolReport) {
        for base in [".lmstudio/models", ".cache/lm-studio/models"] {
            let root = ctx.url(base)
            guard let publishers = ctx.children(of: root) else { continue }
            if let loc = ctx.location(root, title: "모델 폴더", role: .models, protected: false) {
                report.locations.append(loc)
            }
            for publisher in publishers where ctx.isDirectory(publisher) {
                for model in ctx.children(of: publisher) ?? [] where ctx.isDirectory(model) {
                    addModel(ctx, url: model, title: "\(publisher.lastPathComponent)/\(model.lastPathComponent)",
                             guards: [.app("ai.elementlabs.lmstudio", "LM Studio")], rule: "ai.lmstudio.model", into: &report)
                }
            }
        }
    }

    static func scanHuggingFace(_ ctx: ScanContext, into report: inout ToolReport) {
        let hub = ctx.url(".cache/huggingface/hub")
        guard let entries = ctx.children(of: hub) else { return }
        if let loc = ctx.location(hub, title: "Hub 모델·데이터셋", role: .models, protected: false) {
            report.locations.append(loc)
        }
        for entry in entries {
            let name = entry.lastPathComponent
            let isModel = name.hasPrefix("models--"), isDataset = name.hasPrefix("datasets--")
            guard isModel || isDataset else { continue }
            let display = name.split(separator: "-", omittingEmptySubsequences: true).dropFirst().joined(separator: "-")
                .replacingOccurrences(of: "--", with: "/")
            let pretty = name.components(separatedBy: "--").dropFirst().joined(separator: "/")
            addModel(ctx, url: entry, title: (isDataset ? "데이터셋 " : "") + (pretty.isEmpty ? display : pretty),
                     guards: [], rule: "ai.huggingface.model", into: &report)
        }
    }

    private static func addModel(_ ctx: ScanContext, url: URL, title: String, guards: [ProcessGuard], rule: String,
                                 into report: inout ToolReport) {
        guard let root = ctx.policy.allowedRoot(containing: PathUtilities.canonicalPath(url.path) ?? url.path) else { return }
        let spec = CandidateSpec(
            title: title, category: .aiModels, ruleID: rule, risk: .manual,
            riskReason: "사용자가 내려받은 모델 — 캐시가 아님",
            impact: "휴지통으로 이동합니다. 다시 사용하려면 모델을 다시 내려받아야 합니다.",
            regenerable: false, guards: guards, preferredMethod: .trash, allowsPermanentRemoval: false,
            toleratesContentChanges: true, minimumSize: 10 * 1024 * 1024)
        if let c = ctx.makeCandidate(at: url, root: URL(fileURLWithPath: root), spec: spec) {
            report.candidates.append(c)
        }
    }
}
