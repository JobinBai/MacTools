import Foundation
import Combine
import SwiftUI
import MacToolsPluginKit

@MainActor
public final class HomebrewController: ObservableObject {
    @Published public var isBrewAvailable = false
    @Published public var brewPath = ""
    
    @Published public var installedPackages: [BrewPackage] = []
    @Published public var outdatedPackages: [BrewPackage] = []
    @Published public var taps: [BrewTap] = []
    
    // Search states
    @Published public var searchQuery = ""
    @Published public var searchResults: [BrewPackage] = []
    @Published public var isSearching = false
    
    // Command & console states
    @Published public var logs: [BrewCommandLog] = []
    @Published public var isBusy = false
    @Published public var currentOperationName = ""
    
    public var onStateChange: (() -> Void)?
    
    let runner: any HomebrewCommandRunning
    private let localization: PluginLocalization
    
    public init(
        runner: any HomebrewCommandRunning = HomebrewCommandRunner(),
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.runner = runner
        self.localization = localization

        if let customPath = UserDefaults.standard.string(forKey: "mactools.homebrew.customPath"),
           !customPath.isEmpty {
            if let validatedPath = HomebrewExecutableValidator.validatedPath(for: customPath) {
                self.brewPath = validatedPath
                self.isBrewAvailable = true
                return
            }
            UserDefaults.standard.removeObject(forKey: "mactools.homebrew.customPath")
        }

        if let path = discoverBrewPath() {
            self.brewPath = path
            self.isBrewAvailable = true
        }
    }
    
    public func updateCustomPath(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            UserDefaults.standard.removeObject(forKey: "mactools.homebrew.customPath")
            if let path = discoverBrewPath() {
                self.brewPath = path
                self.isBrewAvailable = true
            } else {
                self.brewPath = ""
                self.isBrewAvailable = false
            }
            onStateChange?()
            return
        }

        guard let validatedPath = HomebrewExecutableValidator.validatedPath(for: trimmed) else {
            appendLog(localization.string(
                "log.path.invalid",
                defaultValue: "[System] Homebrew 路径无效，请选择可执行的 brew 文件。"
            ), isError: true)
            onStateChange?()
            return
        }

        UserDefaults.standard.set(validatedPath, forKey: "mactools.homebrew.customPath")
        self.brewPath = validatedPath
        self.isBrewAvailable = true
        appendLog(localization.string("log.path.updated", defaultValue: "[System] 已更新 Homebrew 路径。"))
        onStateChange?()
    }
    
    // MARK: - Path Discovery
    
    private func discoverBrewPath() -> String? {
        for path in HomebrewExecutableValidator.standardPaths {
            if let validatedPath = HomebrewExecutableValidator.validatedPath(for: path) {
                return validatedPath
            }
        }
        
        // Check current ProcessInfo PATH
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            let dirs = envPath.components(separatedBy: ":")
            for dir in dirs {
                let path = (dir as NSString).appendingPathComponent("brew")
                if let validatedPath = HomebrewExecutableValidator.validatedPath(for: path) {
                    return validatedPath
                }
            }
        }
        return nil
    }
    
    // MARK: - Logs Management
    
    public func clearLogs() {
        logs.removeAll()
    }
    
    private func appendLog(_ text: String, isError: Bool = false) {
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .newlines)
            if !trimmed.isEmpty {
                logs.append(BrewCommandLog(text: trimmed, isError: isError))
            }
        }
        if logs.count > 1000 {
            logs.removeFirst(logs.count - 1000)
        }
    }
    
    // MARK: - Scanning Packages
    
    public func scanAll() {
        guard isBrewAvailable, !isBusy else { return }
        isBusy = true
        currentOperationName = localization.string("operation.scanAll", defaultValue: "正在扫描包与更新...")
        clearLogs()
        appendLog(localization.string("log.scan.started", defaultValue: "[System] 开始扫描 Homebrew 状态..."))
        
        Task {
            do {
                // 1. Load active Taps
                try await loadTaps()
                
                // 2. Load installed packages (fast list first)
                try await loadInstalledPackagesFast()
                
                // 3. Load outdated packages
                try await loadOutdatedPackages()
                
                // 4. Load full package details in background (desc, homepage, etc.)
                try await loadPackageDetails()
                
                appendLog(localization.string("log.scan.completed", defaultValue: "[System] 扫描完成。"))
            } catch {
                appendLog(localization.format(
                    "log.scan.failed",
                    defaultValue: "[System] 扫描发生错误：%@",
                    error.localizedDescription
                ), isError: true)
            }
            
            isBusy = false
            currentOperationName = ""
            onStateChange?()
        }
    }
    
    private func loadTaps() async throws {
        appendLog(localization.string("log.taps.loading", defaultValue: "[System] 正在获取已启用的软件源..."))
        let tempRunner = self.runner
        var outputLines: [String] = []
        
        _ = try await tempRunner.run(
            executable: brewPath,
            arguments: ["tap"],
            onOutput: { text in
                outputLines.append(text)
            },
            onError: { _ in }
        )
        
        let rawOutput = outputLines.joined()
        let tapNames = rawOutput.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        taps = tapNames.map { BrewTap(name: $0) }
        appendLog(localization.format("log.taps.loaded", defaultValue: "[System] 获取到 %d 个软件源", taps.count))
    }
    
    private func loadInstalledPackagesFast() async throws {
        appendLog(localization.string("log.installed.loading", defaultValue: "[System] 正在获取已安装包列表..."))
        let tempRunner = self.runner
        
        var formulaOutput = ""
        _ = try await tempRunner.run(
            executable: brewPath,
            arguments: ["list", "--formula", "--versions"],
            onOutput: { formulaOutput += $0 },
            onError: { _ in }
        )
        
        var caskOutput = ""
        _ = try await tempRunner.run(
            executable: brewPath,
            arguments: ["list", "--cask", "--versions"],
            onOutput: { caskOutput += $0 },
            onError: { _ in }
        )
        
        var tempPackages: [BrewPackage] = []
        
        // Parse Formulae
        for line in formulaOutput.components(separatedBy: .newlines) {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count >= 2 else { continue }
            let name = parts[0]
            let version = parts[1]
            tempPackages.append(BrewPackage(
                name: name,
                version: version,
                latestVersion: version,
                isCask: false,
                desc: "",
                homepage: "",
                isOutdated: false,
                isPinned: false
            ))
        }
        
        // Parse Casks
        for line in caskOutput.components(separatedBy: .newlines) {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count >= 2 else { continue }
            let name = parts[0]
            let version = parts[1]
            tempPackages.append(BrewPackage(
                name: name,
                version: version,
                latestVersion: version,
                isCask: true,
                desc: "",
                homepage: "",
                isOutdated: false,
                isPinned: false
            ))
        }
        
        self.installedPackages = tempPackages.sorted { $0.name.lowercased() < $1.name.lowercased() }
        appendLog(localization.format("log.installed.loaded", defaultValue: "[System] 已加载 %d 个已安装包", installedPackages.count))
    }
    
    private func loadOutdatedPackages() async throws {
        appendLog(localization.string("log.outdated.loading", defaultValue: "[System] 正在获取待更新包列表..."))
        let tempRunner = self.runner
        var jsonOutput = ""
        
        _ = try await tempRunner.run(
            executable: brewPath,
            arguments: ["outdated", "--json=v2"],
            onOutput: { jsonOutput += $0 },
            onError: { _ in }
        )
        
        guard let data = jsonOutput.data(using: .utf8) else { return }
        
        struct OutdatedResponse: Codable {
            let formulae: [OutdatedFormulaInfo]
            let casks: [OutdatedCaskInfo]
        }
        struct OutdatedFormulaInfo: Codable {
            let name: String
            let installed_versions: [String]
            let current_version: String
            let pinned: Bool
        }
        struct OutdatedCaskInfo: Codable {
            let name: String
            let installed_versions: [String]
            let current_version: String
        }
        
        do {
            let response = try JSONDecoder().decode(OutdatedResponse.self, from: data)
            
            var tempOutdated: [BrewPackage] = []
            var outdatedNames = Set<String>()
            var latestVersions: [String: String] = [:]
            var pinnedStatus: [String: Bool] = [:]
            
            for item in response.formulae {
                outdatedNames.insert(item.name)
                latestVersions[item.name] = item.current_version
                pinnedStatus[item.name] = item.pinned
                
                tempOutdated.append(BrewPackage(
                    name: item.name,
                    version: item.installed_versions.first ?? "",
                    latestVersion: item.current_version,
                    isCask: false,
                    desc: "",
                    homepage: "",
                    isOutdated: true,
                    isPinned: item.pinned
                ))
            }
            
            for item in response.casks {
                outdatedNames.insert(item.name)
                latestVersions[item.name] = item.current_version
                
                tempOutdated.append(BrewPackage(
                    name: item.name,
                    version: item.installed_versions.first ?? "",
                    latestVersion: item.current_version,
                    isCask: true,
                    desc: "",
                    homepage: "",
                    isOutdated: true,
                    isPinned: false
                ))
            }
            
            self.outdatedPackages = tempOutdated.sorted { $0.name.lowercased() < $1.name.lowercased() }
            
            // Update outdated flag and latestVersion in installedPackages
            self.installedPackages = self.installedPackages.map { pkg in
                let isOutdated = outdatedNames.contains(pkg.name)
                let latestVer = latestVersions[pkg.name] ?? pkg.version
                let isPinned = pinnedStatus[pkg.name] ?? pkg.isPinned
                return BrewPackage(
                    name: pkg.name,
                    version: pkg.version,
                    latestVersion: latestVer,
                    isCask: pkg.isCask,
                    desc: pkg.desc,
                    homepage: pkg.homepage,
                    isOutdated: isOutdated,
                    isPinned: isPinned,
                    dependencies: pkg.dependencies
                )
            }
            
            appendLog(localization.format("log.outdated.loaded", defaultValue: "[System] 获取到 %d 个待更新包", outdatedPackages.count))
        } catch {
            appendLog(localization.format(
                "log.outdated.parseFailed",
                defaultValue: "[System] 解析待更新包失败：%@",
                error.localizedDescription
            ), isError: true)
        }
    }
    
    private func loadPackageDetails() async throws {
        appendLog(localization.string("log.details.loading", defaultValue: "[System] 正在加载包详细元数据..."))
        let tempRunner = self.runner
        var jsonOutput = ""
        
        _ = try await tempRunner.run(
            executable: brewPath,
            arguments: ["info", "--json=v2", "--installed"],
            onOutput: { jsonOutput += $0 },
            onError: { _ in }
        )
        
        guard let data = jsonOutput.data(using: .utf8) else { return }
        
        struct BrewInfoResponse: Codable {
            let formulae: [FormulaInfo]
            let casks: [CaskInfo]
        }
        struct FormulaInfo: Codable {
            let name: String
            let desc: String?
            let homepage: String?
            let dependencies: [String]?
        }
        struct CaskInfo: Codable {
            let token: String
            let name: [String]?
            let desc: String?
            let homepage: String?
        }
        
        do {
            let response = try JSONDecoder().decode(BrewInfoResponse.self, from: data)
            
            var details: [String: (desc: String, homepage: String, deps: [String])] = [:]
            for item in response.formulae {
                details[item.name] = (
                    desc: item.desc ?? "",
                    homepage: item.homepage ?? "",
                    deps: item.dependencies ?? []
                )
            }
            for item in response.casks {
                details[item.token] = (
                    desc: item.desc ?? (item.name?.first ?? ""),
                    homepage: item.homepage ?? "",
                    deps: []
                )
            }
            
            // Map details back to installedPackages and outdatedPackages
            self.installedPackages = self.installedPackages.map { pkg in
                if let detail = details[pkg.name] {
                    return BrewPackage(
                        name: pkg.name,
                        version: pkg.version,
                        latestVersion: pkg.latestVersion,
                        isCask: pkg.isCask,
                        desc: detail.desc,
                        homepage: detail.homepage,
                        isOutdated: pkg.isOutdated,
                        isPinned: pkg.isPinned,
                        dependencies: detail.deps
                    )
                }
                return pkg
            }
            
            self.outdatedPackages = self.outdatedPackages.map { pkg in
                if let detail = details[pkg.name] {
                    return BrewPackage(
                        name: pkg.name,
                        version: pkg.version,
                        latestVersion: pkg.latestVersion,
                        isCask: pkg.isCask,
                        desc: detail.desc,
                        homepage: detail.homepage,
                        isOutdated: pkg.isOutdated,
                        isPinned: pkg.isPinned,
                        dependencies: detail.deps
                    )
                }
                return pkg
            }
            
            appendLog(localization.string("log.details.loaded", defaultValue: "[System] 包详细元数据加载完成"))
        } catch {
            appendLog(localization.format(
                "log.details.parseFailed",
                defaultValue: "[System] 解析详细元数据失败：%@",
                error.localizedDescription
            ), isError: true)
        }
    }
    
    // MARK: - Search
    
    public func search(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults.removeAll()
            return
        }
        guard !isSearching else { return }
        guard searchQuery != trimmed || searchResults.isEmpty else { return }
        
        searchQuery = trimmed
        isSearching = true
        searchResults.removeAll()
        
        Task {
            do {
                let tempRunner = self.runner
                
                // Search formulae
                var formulaOutput = ""
                _ = try await tempRunner.run(
                    executable: brewPath,
                    arguments: ["search", "--formula", trimmed],
                    onOutput: { formulaOutput += $0 },
                    onError: { _ in }
                )
                
                // Search casks
                var caskOutput = ""
                _ = try await tempRunner.run(
                    executable: brewPath,
                    arguments: ["search", "--cask", trimmed],
                    onOutput: { caskOutput += $0 },
                    onError: { _ in }
                )
                
                var results: [BrewPackage] = []
                
                let formulae = formulaOutput.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                
                let casks = caskOutput.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                
                for f in formulae {
                    results.append(BrewPackage(
                        name: f,
                        version: "",
                        latestVersion: "",
                        isCask: false,
                        desc: "",
                        homepage: "",
                        isOutdated: false,
                        isPinned: false
                    ))
                }
                
                for c in casks {
                    results.append(BrewPackage(
                        name: c,
                        version: "",
                        latestVersion: "",
                        isCask: true,
                        desc: "",
                        homepage: "",
                        isOutdated: false,
                        isPinned: false
                    ))
                }
                
                self.searchResults = results.sorted { $0.name.lowercased() < $1.name.lowercased() }
            } catch {}
            
            isSearching = false
        }
    }
    
    // MARK: - Package Actions
    
    public func install(package: BrewPackage) {
        runAsyncCommand(
            name: localization.format("operation.install", defaultValue: "正在安装 %@...", package.name),
            args: ["install"] + (package.isCask ? ["--cask"] : []) + [package.name]
        ) { [weak self] success in
            if success {
                self?.scanAll()
            }
        }
    }
    
    public func uninstall(package: BrewPackage) {
        runAsyncCommand(
            name: localization.format("operation.uninstall", defaultValue: "正在卸载 %@...", package.name),
            args: ["uninstall"] + (package.isCask ? ["--cask"] : []) + [package.name]
        ) { [weak self] success in
            if success {
                self?.scanAll()
            }
        }
    }
    
    public func upgrade(package: BrewPackage) {
        runAsyncCommand(
            name: localization.format("operation.upgrade", defaultValue: "正在更新 %@...", package.name),
            args: ["upgrade"] + (package.isCask ? ["--cask"] : []) + [package.name]
        ) { [weak self] success in
            if success {
                self?.scanAll()
            }
        }
    }
    
    public func pin(package: BrewPackage) {
        runAsyncCommand(
            name: localization.format("operation.pin", defaultValue: "正在锁定 %@...", package.name),
            args: ["pin", package.name]
        ) { [weak self] success in
            if success {
                self?.scanAll()
            }
        }
    }
    
    public func unpin(package: BrewPackage) {
        runAsyncCommand(
            name: localization.format("operation.unpin", defaultValue: "正在解锁 %@...", package.name),
            args: ["unpin", package.name]
        ) { [weak self] success in
            if success {
                self?.scanAll()
            }
        }
    }
    
    // MARK: - Global Operations
    
    public func upgradeAll() {
        runAsyncCommand(name: localization.string("operation.upgradeAll", defaultValue: "正在更新所有包..."), args: ["upgrade"]) { [weak self] success in
            if success {
                self?.scanAll()
            }
        }
    }
    
    public func updateBrew() {
        runAsyncCommand(name: localization.string("operation.updateBrew", defaultValue: "正在更新 Homebrew 源..."), args: ["update"]) { [weak self] success in
            if success {
                self?.scanAll()
            }
        }
    }
    
    public func runDoctor() {
        runAsyncCommand(name: localization.string("operation.doctor", defaultValue: "正在运行 Homebrew 诊断..."), args: ["doctor"]) { _ in }
    }
    
    public func runCleanup() {
        runAsyncCommand(name: localization.string("operation.cleanup", defaultValue: "正在清理 Homebrew 缓存..."), args: ["cleanup"]) { _ in }
    }
    
    // MARK: - Tap Actions
    
    public func tapRepository(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        runAsyncCommand(name: localization.format("operation.tap", defaultValue: "正在启用软件源 %@...", trimmed), args: ["tap", trimmed]) { [weak self] success in
            if success {
                self?.scanAll()
            }
        }
    }
    
    public func untapRepository(tap: BrewTap) {
        runAsyncCommand(name: localization.format("operation.untap", defaultValue: "正在移除软件源 %@...", tap.name), args: ["untap", tap.name]) { [weak self] success in
            if success {
                self?.scanAll()
            }
        }
    }
    
    // MARK: - Process Execution
    
    private func runAsyncCommand(
        name: String,
        args: [String],
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard isBrewAvailable, !isBusy else { return }
        isBusy = true
        currentOperationName = name
        clearLogs()
        appendLog("[Command] brew \(args.joined(separator: " "))")
        
        Task { [self] in
            let success: Bool
            do {
                let status = try await runner.run(
                    executable: brewPath,
                    arguments: args,
                    onOutput: { [weak self] text in
                        self?.appendLog(text)
                    },
                    onError: { [weak self] text in
                        self?.appendLog(text, isError: true)
                    }
                )
                
                success = (status == 0)
                appendLog(
                    success
                        ? localization.string("log.command.completed", defaultValue: "[System] 操作成功完成")
                        : localization.format("log.command.failedStatus", defaultValue: "[System] 操作失败，错误码：%d", status),
                    isError: !success
                )
            } catch {
                appendLog(localization.format(
                    "log.command.failed",
                    defaultValue: "[System] 执行命令出错：%@",
                    error.localizedDescription
                ), isError: true)
                success = false
            }
            
            isBusy = false
            currentOperationName = ""
            onStateChange?()
            completion(success)
        }
    }
    
    public func cancelCurrentOperation() {
        Task {
            await runner.cancel()
            appendLog(localization.string("log.command.cancelled", defaultValue: "[System] 操作已被用户取消"), isError: true)
            isBusy = false
            currentOperationName = ""
            onStateChange?()
        }
    }
}
