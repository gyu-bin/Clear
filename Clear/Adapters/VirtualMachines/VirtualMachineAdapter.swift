import Foundation

/// Virtual machines kept on disk: the Claude desktop app's workspace VM, and
/// UTM, Parallels and VirtualBox machines. Each is offered whole, only by the
/// user's choice, only while its app is closed, and to the Trash unless the app
/// can download it again.
struct VirtualMachineAdapter: ToolAdapter {
    let id = "vm"
    let name = "가상머신"
    let symbol = "desktopcomputer"
    let kind = ToolKind.developer

    static let minimumSize: Int64 = 100 * 1024 * 1024

    func scan(_ ctx: ScanContext) async -> ToolReport {
        var report = ToolReport(id: id, name: name, symbol: symbol, kind: kind, installed: false)
        ctx.progress(ScanProgress(phase: "가상머신 찾는 중"))

        // Claude desktop: the VM image behind its sandboxed workspace (Cowork).
        let claude = ctx.url("Library/Application Support/Claude")
        for bundle in ctx.children(of: claude.appendingPathComponent("vm_bundles")) ?? []
        where bundle.pathExtension == "bundle" && ctx.isDirectory(bundle) {
            add(bundle, root: claude, title: "Claude 데스크톱 가상머신", ruleID: "vm.claude",
                reason: "Claude 데스크톱이 작업 공간(Cowork 등)에 쓰는 가상머신 이미지 — 다시 쓰면 앱이 다시 내려받음",
                impact: "휴지통으로 이동합니다. 문제가 생기면 휴지통에서 되돌릴 수 있습니다.",
                guards: [.app("com.anthropic.claudefordesktop", "Claude")], ctx: ctx, into: &report)
        }

        // UTM (sandboxed): one .utm bundle per machine.
        let containers = ctx.url("Library/Containers")
        for vm in ctx.children(of: ctx.url("Library/Containers/com.utmapp.UTM/Data/Documents")) ?? []
        where vm.pathExtension == "utm" {
            add(vm, root: containers, title: "UTM · \(vm.deletingPathExtension().lastPathComponent)", ruleID: "vm.utm",
                reason: "가상머신 안의 시스템과 파일이 모두 사라집니다", impact: userDataImpact,
                guards: [.app("com.utmapp.UTM", "UTM")], ctx: ctx, into: &report)
        }

        // Parallels: ~/Parallels/<name>.pvm
        let parallels = ctx.url("Parallels")
        for vm in ctx.children(of: parallels) ?? [] where vm.pathExtension == "pvm" {
            add(vm, root: parallels, title: "Parallels · \(vm.deletingPathExtension().lastPathComponent)", ruleID: "vm.parallels",
                reason: "가상머신 안의 시스템과 파일이 모두 사라집니다", impact: userDataImpact,
                guards: [.app("com.parallels.desktop.console", "Parallels Desktop")], ctx: ctx, into: &report)
        }

        // VirtualBox: ~/VirtualBox VMs/<name>/
        let vbox = ctx.url("VirtualBox VMs")
        for vm in ctx.children(of: vbox) ?? [] where ctx.isDirectory(vm) && !vm.lastPathComponent.hasPrefix(".") {
            add(vm, root: vbox, title: "VirtualBox · \(vm.lastPathComponent)", ruleID: "vm.virtualbox",
                reason: "가상머신 안의 시스템과 파일이 모두 사라집니다", impact: userDataImpact,
                guards: [.app("org.virtualbox.app.VirtualBox", "VirtualBox"), .process("VBoxHeadless")], ctx: ctx, into: &report)
        }

        report.installed = !report.candidates.isEmpty
        report.locations = report.candidates.compactMap { c in
            c.path.map { ToolLocation(path: $0, title: c.title, role: .other, size: c.size, isProtected: false, note: nil) }
        }
        return report
    }

    private var userDataImpact: String { "휴지통으로 이동합니다. 휴지통을 비우기 전까지 되돌릴 수 있습니다." }

    private func add(_ url: URL, root: URL, title: String, ruleID: String, reason: String, impact: String,
                     guards: [ProcessGuard], ctx: ScanContext, into report: inout ToolReport) {
        let spec = CandidateSpec(
            id: "vm:\(url.path)", title: title, category: .virtualMachine, ruleID: ruleID,
            risk: .manual, riskReason: reason, impact: impact, regenerable: ruleID == "vm.claude", guards: guards,
            preferredMethod: .trash, allowsPermanentRemoval: false, minimumSize: Self.minimumSize)
        guard var c = ctx.makeCandidate(at: url, root: root, spec: spec) else { return }
        if c.risk != .blocked, !c.runningGuards.isEmpty {
            c.risk = .blocked
            c.riskReason = "\(c.runningGuards.joined(separator: ", ")) 실행 중 — 앱을 종료한 뒤 다시 스캔하세요"
        }
        if let last = c.size.newestModification, c.risk != .blocked {
            c.riskReason += " · 마지막 사용 \(GeneralCleanupScanner.idleText(ctx.scannedAt.timeIntervalSince(last)))"
        }
        report.candidates.append(c)
    }
}
