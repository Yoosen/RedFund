import Foundation

/// 应用更新服务：检测 GitHub Releases 更新、下载更新包并安装替换当前 App。
struct AppUpdateService: Sendable {
    /// 更新过程中的错误类型。
    enum UpdateError: LocalizedError {
        case invalidResponse
        case noReleaseURL
        case noDownloadURL
        case unsupportedPackage(String)
        case invalidCurrentApp
        case appNotFoundInArchive
        case bundleIdentifierMismatch
        case stagedVersionMismatch
        case translocatedApp
        case installLocationNotWritable(String)
        case toolFailed(String)
        case installerLaunchFailed(String)
        case checkTimedOut

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                "更新接口返回异常"
            case .noReleaseURL:
                "未找到可打开的更新地址"
            case .noDownloadURL:
                "未找到可下载的更新包"
            case .unsupportedPackage(let fileName):
                "暂不支持自动安装该更新包：\(fileName)"
            case .invalidCurrentApp:
                "当前应用不是可替换的 .app 包"
            case .appNotFoundInArchive:
                "更新包中未找到可安装的 .app"
            case .bundleIdentifierMismatch:
                "更新包应用标识与当前应用不一致"
            case .stagedVersionMismatch:
                "更新包版本与发布版本不一致"
            case .translocatedApp:
                "当前应用处于 App Translocation，无法自动更新。请先移动到“应用程序”后重试"
            case .installLocationNotWritable(let path):
                "当前安装目录不可写：\(path)"
            case .toolFailed(let message):
                "更新工具执行失败：\(message)"
            case .installerLaunchFailed(let message):
                "启动更新安装器失败：\(message)"
            case .checkTimedOut:
                "检查更新超时，请稍后重试"
            }
        }
    }

    /// 网络会话。
    private let session: URLSession
    /// 最新发布页（用于重定向解析最新 tag）。
    private let latestReleaseURL = URL(string: "https://github.com/Yoosen/RedFund/releases/latest")!
    /// 发布列表基础地址。
    private let releasesBaseURL = URL(string: "https://github.com/Yoosen/RedFund/releases")!
    /// 交互式检查超时（秒）。
    private let interactiveAPIRequestTimeout: TimeInterval
    /// 发布订阅信息（latest-mac.yml）请求超时。
    private let releaseFeedRequestTimeout: TimeInterval
    /// 后台检查超时（秒）。
    private let backgroundAPIRequestTimeout: TimeInterval

    /// 初始化，可注入会话与各阶段超时。
    init(
        session: URLSession = .shared,
        interactiveAPIRequestTimeout: TimeInterval = 5,
        releaseFeedRequestTimeout: TimeInterval = 4,
        backgroundAPIRequestTimeout: TimeInterval = 8
    ) {
        self.session = session
        self.interactiveAPIRequestTimeout = interactiveAPIRequestTimeout
        self.releaseFeedRequestTimeout = releaseFeedRequestTimeout
        self.backgroundAPIRequestTimeout = backgroundAPIRequestTimeout
    }

    /// 检查更新：交互模式带超时，后台模式用更长超时。
    func check(currentVersion: String, mode: AppUpdateCheckMode = .background) async throws -> AppUpdateStatus {
        switch mode {
        case .interactive:
            return try await withTimeout(seconds: interactiveAPIRequestTimeout) {
                try await checkWithReleaseFeedFallback(
                    currentVersion: currentVersion,
                    apiTimeout: interactiveAPIRequestTimeout
                )
            }
        case .background:
            return try await checkWithReleaseFeedFallback(
                currentVersion: currentVersion,
                apiTimeout: backgroundAPIRequestTimeout
            )
        }
    }

    /// 先尝试 GitHub API，失败则回退到 Mac 发布订阅信息。
    private func checkWithReleaseFeedFallback(
        currentVersion: String,
        apiTimeout: TimeInterval
    ) async throws -> AppUpdateStatus {
        do {
            return try await checkGitHubAPI(
                currentVersion: currentVersion,
                timeout: apiTimeout
            )
        } catch {
            return try await checkMacReleaseFeed(currentVersion: currentVersion)
        }
    }

    /// 下载更新包：校验为 zip、落盘到更新目录并执行解压暂存。
    func downloadPackage(
        for info: AppUpdateInfo,
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> AppUpdatePackage {
        guard let downloadURL = info.downloadURL else {
            throw UpdateError.noDownloadURL
        }

        let fileName = downloadURL.lastPathComponent.removingPercentEncoding ?? downloadURL.lastPathComponent
        guard fileName.lowercased().hasSuffix(".zip") else {
            throw UpdateError.unsupportedPackage(fileName)
        }

        var request = URLRequest(url: downloadURL)
        request.setValue("red-fund-swift", forHTTPHeaderField: "User-Agent")
        let updateDirectory = try prepareUpdateDirectory()
        let destinationURL = updateDirectory.appending(path: fileName)
        let downloadedURL = try await downloadFile(
            request: request,
            destinationURL: destinationURL,
            progressHandler: progressHandler
        )
        let stagedAppURL = try stageApp(from: downloadedURL, in: updateDirectory, expectedInfo: info)

        return AppUpdatePackage(localURL: downloadedURL, stagedAppURL: stagedAppURL, downloadedAt: .now)
    }

    /// 安装更新包：编写并执行安装脚本替换当前 App。
    func installPackage(_ package: AppUpdatePackage, currentAppURL: URL, processIdentifier: Int32) throws {
        guard currentAppURL.pathExtension == "app" else {
            throw UpdateError.invalidCurrentApp
        }
        if currentAppURL.path.contains("/AppTranslocation/") {
            throw UpdateError.translocatedApp
        }

        let parentURL = currentAppURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parentURL.path) else {
            throw UpdateError.installLocationNotWritable(parentURL.path)
        }

        let updateDirectory = try prepareUpdateDirectory(removeExisting: false)
        let scriptURL = updateDirectory.appending(path: "install-\(UUID().uuidString).sh")
        let logURL = updateDirectory.appending(path: "install.log")
        try installScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            scriptURL.path,
            currentAppURL.path,
            package.stagedAppURL.path,
            String(processIdentifier),
            logURL.path
        ]
        do {
            try process.run()
        } catch {
            throw UpdateError.installerLaunchFailed(error.localizedDescription)
        }
    }

    /// 回退方案：解析 latest-mac.yml 获取版本与下载地址。
    private func checkMacReleaseFeed(currentVersion: String) async throws -> AppUpdateStatus {
        let tag = try await resolveLatestTag()
        let feedURL = releasesBaseURL
            .appending(path: "download")
            .appending(path: tag)
            .appending(path: "latest-mac.yml")
        var request = URLRequest(url: feedURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = releaseFeedRequestTimeout
        request.setValue("red-fund-swift", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw UpdateError.invalidResponse
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw UpdateError.invalidResponse
        }

        let feed = MacReleaseFeed.parse(text)
        let latestVersion = normalizedVersion(feed.version ?? tag)
        let htmlURL = releasesBaseURL.appending(path: "tag").appending(path: tag)
        let downloadURL = preferredDownloadURL(from: feed.files, tag: tag)
        if VersionComparator.isVersion(latestVersion, newerThan: currentVersion),
           downloadURL == nil {
            throw UpdateError.noDownloadURL
        }
        let info = AppUpdateInfo(
            version: latestVersion,
            releaseName: "Red Fund \(latestVersion)",
            releaseNotes: "",
            publishedAt: feed.releaseDate,
            htmlURL: htmlURL,
            downloadURL: downloadURL
        )

        if VersionComparator.isVersion(latestVersion, newerThan: currentVersion) {
            return .available(info)
        }

        return .upToDate(.now)
    }

    /// 主方案：调用 GitHub API 获取最新 release 信息。
    private func checkGitHubAPI(currentVersion: String, timeout: TimeInterval) async throws -> AppUpdateStatus {
        let apiURL = URL(string: "https://api.github.com/repos/Yoosen/RedFund/releases/latest")!
        var request = URLRequest(url: latestReleaseURL)
        request.url = apiURL
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = timeout
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("red-fund-swift", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw UpdateError.invalidResponse
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let release = try decoder.decode(GitHubRelease.self, from: data)
        guard let htmlURL = URL(string: release.htmlURL) else {
            throw UpdateError.noReleaseURL
        }

        let latestVersion = normalizedVersion(release.tagName)
        let downloadURL = preferredDownloadURL(from: release.assets)
        if VersionComparator.isVersion(latestVersion, newerThan: currentVersion),
           downloadURL == nil {
            throw UpdateError.noDownloadURL
        }
        let info = AppUpdateInfo(
            version: latestVersion,
            releaseName: release.name ?? release.tagName,
            releaseNotes: release.body ?? "",
            publishedAt: release.publishedAt,
            htmlURL: htmlURL,
            downloadURL: downloadURL
        )

        if VersionComparator.isVersion(latestVersion, newerThan: currentVersion) {
            return .available(info)
        }

        return .upToDate(.now)
    }

    /// 带超时的竞速封装：操作与超时任务先完成者胜出。
    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let race = TimeoutRace<T>()
        let operationTask = Task {
            do {
                await race.resume(.success(try await operation()))
            } catch {
                await race.resume(.failure(error))
            }
        }
        let timeoutTask = Task {
            do {
                let nanoseconds = UInt64(max(seconds, 0) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                await race.resume(.failure(UpdateError.checkTimedOut))
            } catch {
                await race.resume(.failure(error))
            }
        }

        defer {
            operationTask.cancel()
            timeoutTask.cancel()
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    await race.setContinuation(continuation)
                }
            }
        } onCancel: {
            operationTask.cancel()
            timeoutTask.cancel()
        }
    }

    /// 从最新发布页重定向中解析出最新 tag。
    private func resolveLatestTag() async throws -> String {
        var request = URLRequest(url: latestReleaseURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = releaseFeedRequestTimeout
        request.setValue("red-fund-swift", forHTTPHeaderField: "User-Agent")
        let (_, response) = try await session.data(for: request)
        guard let finalURL = response.url,
              let tag = finalURL.pathComponents.last,
              tag != "latest"
        else {
            throw UpdateError.invalidResponse
        }
        return tag
    }

    /// 去除版本号前后的 v/V 与空格。
    private func normalizedVersion(_ version: String) -> String {
        version.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
    }

    /// 从 GitHub 资源列表中按评分选取最佳 zip 下载地址。
    private func preferredDownloadURL(from assets: [GitHubRelease.Asset]) -> URL? {
        let sortedAssets = assets.sorted { lhs, rhs in
            assetScore(lhs.name) > assetScore(rhs.name)
        }
        return sortedAssets
            .filter { $0.name.lowercased().hasSuffix(".zip") }
            .compactMap { URL(string: $0.browserDownloadURL) }
            .first
    }

    /// 从 Mac 发布订阅文件中按评分选取下载地址。
    private func preferredDownloadURL(from files: [MacReleaseFeed.File], tag: String) -> URL? {
        let sortedFiles = files.sorted { lhs, rhs in
            assetScore(lhs.url) > assetScore(rhs.url)
        }
        guard let file = sortedFiles.first(where: { $0.url.lowercased().hasSuffix(".zip") }) else { return nil }
        return releasesBaseURL
            .appending(path: "download")
            .appending(path: tag)
            .appending(path: file.url)
    }

    /// 资源评分：架构匹配/zip/dmg/swift 关键字加分，用于选取最合适包。
    private func assetScore(_ name: String) -> Int {
        let lowercased = name.lowercased()
        var score = 0
        if lowercased.contains(currentArchitecture) { score += 20 }
        if lowercased.hasSuffix(".zip") { score += 10 }
        if lowercased.hasSuffix(".dmg") { score += 1 }
        if lowercased.contains("swift") { score += 2 }
        return score
    }

    /// 当前 CPU 架构字符串（arm64 / x86_64）。
    private var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        ""
        #endif
    }

    /// 校验 HTTP 响应状态码是否为 2xx。
    private func validateHTTPResponse(_ response: URLResponse) throws {
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw UpdateError.invalidResponse
        }
    }

    /// 下载文件并在下载进度变化时回调进度（0~1）。
    private func downloadFile(
        request: URLRequest,
        destinationURL: URL,
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let observation = DownloadObservation()
            let task = session.downloadTask(with: request) { temporaryURL, response, error in
                defer {
                    observation.invalidate()
                }

                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                do {
                    guard let response else {
                        throw UpdateError.invalidResponse
                    }
                    try validateHTTPResponse(response)
                    guard let temporaryURL else {
                        throw UpdateError.invalidResponse
                    }

                    try? FileManager.default.removeItem(at: destinationURL)
                    try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
                    Task { @MainActor in
                        progressHandler(1)
                    }
                    continuation.resume(returning: destinationURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            observation.set(task.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
                let fraction = progress.fractionCompleted
                guard fraction.isFinite else { return }
                let clamped = min(max(fraction, 0), 1)
                Task { @MainActor in
                    progressHandler(clamped)
                }
            })
            task.resume()
        }
    }

    /// 解压 zip 归档并定位其中的 .app。
    private func stageApp(from archiveURL: URL, in updateDirectory: URL, expectedInfo info: AppUpdateInfo) throws -> URL {
        let extractDirectory = updateDirectory.appending(path: "expanded", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: extractDirectory)
        try FileManager.default.createDirectory(at: extractDirectory, withIntermediateDirectories: true)
        try runTool("/usr/bin/ditto", arguments: ["-x", "-k", archiveURL.path, extractDirectory.path])

        guard let appURL = findFirstApp(in: extractDirectory) else {
            throw UpdateError.appNotFoundInArchive
        }
        try verifyStagedApp(appURL, expectedInfo: info)
        return appURL
    }

    /// 校验暂存 App：签名、Bundle ID 一致性、版本不低于预期。
    private func verifyStagedApp(_ appURL: URL, expectedInfo info: AppUpdateInfo) throws {
        try runTool("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", appURL.path])

        guard let stagedBundle = Bundle(url: appURL),
              let stagedBundleID = stagedBundle.bundleIdentifier,
              stagedBundleID == Bundle.main.bundleIdentifier else {
            throw UpdateError.bundleIdentifierMismatch
        }

        let stagedVersion = stagedBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? stagedBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "0"
        guard isVersion(stagedVersion, atLeast: info.version) else {
            throw UpdateError.stagedVersionMismatch
        }
    }

    /// 在目录树中查找第一个 .app。
    private func findFirstApp(in directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let url as URL in enumerator where url.pathExtension == "app" {
            return url
        }
        return nil
    }

    /// 运行命令行工具并校验退出码，非零则抛错。
    private func runTool(_ launchPath: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError.toolFailed((message?.isEmpty == false ? message : nil) ?? "\(launchPath) exited \(process.terminationStatus)")
        }
    }

    /// 判断版本是否不低于预期（相等或更新）。
    private func isVersion(_ version: String, atLeast expectedVersion: String) -> Bool {
        let normalized = normalizedVersion(version)
        let expected = normalizedVersion(expectedVersion)
        return normalized == expected || VersionComparator.isVersion(normalized, newerThan: expected)
    }

    /// 准备更新目录（Application Support/red-fund/Updates）。
    private func prepareUpdateDirectory(removeExisting: Bool = true) throws -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let updateDirectory = baseURL
            .appending(path: "red-fund")
            .appending(path: "Updates")

        if removeExisting {
            try? FileManager.default.removeItem(at: updateDirectory)
        }
        try FileManager.default.createDirectory(at: updateDirectory, withIntermediateDirectories: true)
        return updateDirectory
    }

    /// 安装脚本内容：等待旧 App 退出、备份、ditto 替换、打开新 App、清理备份。
    private var installScript: String {
        """
        #!/bin/sh
        set -eu

        TARGET_APP="$1"
        STAGED_APP="$2"
        APP_PID="$3"
        LOG_FILE="$4"

        {
          echo "red-fund updater started: $(date)"

          i=0
          while /bin/kill -0 "$APP_PID" 2>/dev/null; do
            i=$((i + 1))
            if [ "$i" -gt 120 ]; then
              echo "Timed out waiting for old app to quit"
              exit 1
            fi
            /bin/sleep 0.25
          done

          TARGET_PARENT="$(/usr/bin/dirname "$TARGET_APP")"
          APP_NAME="$(/usr/bin/basename "$TARGET_APP")"
          BACKUP_APP="${TARGET_PARENT}/.${APP_NAME}.red-fund-update-backup.$$"
          /bin/rm -rf "$BACKUP_APP"

          if [ -d "$TARGET_APP" ]; then
            /bin/mv "$TARGET_APP" "$BACKUP_APP"
          fi

          if /usr/bin/ditto "$STAGED_APP" "$TARGET_APP"; then
            /usr/bin/xattr -dr com.apple.quarantine "$TARGET_APP" 2>/dev/null || true
            /usr/bin/open "$TARGET_APP"
            /bin/rm -rf "$BACKUP_APP"
            /bin/rm -rf "$(/usr/bin/dirname "$STAGED_APP")"
            echo "red-fund updater finished: $(date)"
          else
            echo "Copy failed; restoring previous app"
            /bin/rm -rf "$TARGET_APP"
            if [ -d "$BACKUP_APP" ]; then
              /bin/mv "$BACKUP_APP" "$TARGET_APP"
              /usr/bin/open "$TARGET_APP"
            fi
            exit 1
          fi
        } >> "$LOG_FILE" 2>&1
        """
    }
}

/// 超时竞速封装：首个完成者（成功/失败）决定结果，避免重复续体恢复。
private actor TimeoutRace<T: Sendable> {
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?

    /// 设置续体；若已有结果则立即恢复。
    func setContinuation(_ continuation: CheckedContinuation<T, Error>) {
        if let result {
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
        }
    }

    /// 恢复结果；仅首次生效。
    func resume(_ result: Result<T, Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}

/// 下载进度 KVO 观察封装（线程安全）。
private final class DownloadObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var observation: NSKeyValueObservation?

    /// 设置 KVO 观察。
    func set(_ observation: NSKeyValueObservation) {
        lock.lock()
        self.observation = observation
        lock.unlock()
    }

    /// 失效并释放观察。
    func invalidate() {
        lock.lock()
        observation?.invalidate()
        observation = nil
        lock.unlock()
    }
}

/// latest-mac.yml 解析模型。
private struct MacReleaseFeed {
    struct File: Equatable {
        var url: String
    }

    var version: String?
    var releaseDate: Date?
    var files: [File]

    /// 解析 latest-mac.yml 文本为结构化数据。
    static func parse(_ text: String) -> MacReleaseFeed {
        var version: String?
        var releaseDate: Date?
        var files: [File] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("version:") {
                version = value(after: "version:", in: line)
            } else if line.hasPrefix("releaseDate:") {
                let dateText = value(after: "releaseDate:", in: line).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                releaseDate = ISO8601DateFormatter().date(from: dateText)
            } else if line.hasPrefix("- url:") {
                let url = value(after: "- url:", in: line)
                if !url.isEmpty {
                    files.append(File(url: url))
                }
            }
        }

        return MacReleaseFeed(version: version, releaseDate: releaseDate, files: files)
    }

    /// 截取前缀之后的文本并去前后空白。
    private static func value(after prefix: String, in line: String) -> String {
        line
            .dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// GitHub release 解码模型（用于 API 响应）。
private struct GitHubRelease: Decodable {
    var tagName: String
    var name: String?
    var body: String?
    var htmlURL: String
    var publishedAt: Date?
    var assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case assets
    }

    struct Asset: Decodable {
        var name: String
        var browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }
}

/// 版本号比较工具（支持 v 前缀与不定长分段）。
enum VersionComparator {
    /// 判断 lhs 是否比 rhs 更新（分段数值比较）。
    static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let left = components(lhs)
        let right = components(rhs)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r {
                return l > r
            }
        }
        return false
    }

    /// 将版本字符串拆分为整数分段。
    private static func components(_ version: String) -> [Int] {
        version
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            .split(separator: ".")
            .map { part in
                let digits = part.prefix { $0.isNumber }
                return Int(digits) ?? 0
            }
    }
}
