import Foundation
import os.log

/// term-mesh 번들에 포함된 Claude 슬래시 커맨드 파일을
/// 앱 시작 시 ~/.claude/commands/ 에 버전 기반으로 설치한다.
///
/// 설치 조건:
/// - 번들에 claude-commands/ 리소스 디렉토리가 존재
/// - 현재 앱 버전이 마지막 설치 시 버전보다 새로움
/// - 대상 파일이 없거나, "term-mesh-managed" 마커가 있는 파일만 덮어쓰기
///
/// 사용자가 직접 작성한 커맨드 파일(마커 없음)은 절대 건드리지 않는다.
enum ClaudeCommandInstaller {

    private static let logger = Logger(
        subsystem: "com.termmesh",
        category: "ClaudeCommandInstaller"
    )

    /// UserDefaults key: 마지막 설치 시 앱 버전
    private static let installedVersionKey = "termMeshClaudeCommandsInstalledVersion"

    /// 번들 내 커맨드 디렉토리 (claude-commands/)
    private static var bundleCommandsURL: URL? {
        Bundle.main.url(forResource: "claude-commands", withExtension: nil)
    }

    /// 번들 내 스킬 디렉토리 (claude-skills/)
    private static var bundleSkillsURL: URL? {
        Bundle.main.url(forResource: "claude-skills", withExtension: nil)
    }

    /// 대상: ~/.claude/commands/
    private static var targetURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/commands")
    }

    /// 대상: ~/.claude/skills/
    private static var targetSkillsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/skills")
    }

    /// 앱 시작 시 호출. 번들 버전이 더 새로우면 커맨드/스킬 파일을 설치한다.
    /// 에러는 조용히 실패 — 설치 실패가 앱 시작을 막아선 안 된다.
    static func installIfNeeded() {
        let current = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0"
        let installed = UserDefaults.standard.string(forKey: installedVersionKey) ?? ""

        guard isNewer(current, than: installed) else {
            logger.debug("Claude commands/skills already installed for version \(current, privacy: .public)")
            return
        }

        if let src = bundleCommandsURL {
            do {
                try installCommands(from: src, to: targetURL)
                logger.info("Claude commands installed for version \(current, privacy: .public)")
            } catch {
                logger.error("Command install failed: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            logger.error("claude-commands bundle resource not found")
        }

        if let srcSkills = bundleSkillsURL {
            do {
                try installSkills(from: srcSkills, to: targetSkillsURL)
                logger.info("Claude skills installed for version \(current, privacy: .public)")
            } catch {
                logger.error("Skill install failed: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            logger.debug("claude-skills bundle resource not found (optional)")
        }

        UserDefaults.standard.set(current, forKey: installedVersionKey)
    }

    // MARK: - Private

    private static func installCommands(from src: URL, to dst: URL) throws {
        let fm = FileManager.default

        // ~/.claude/commands/ 디렉토리 없으면 생성
        if !fm.fileExists(atPath: dst.path) {
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        }

        let files = try fm.contentsOfDirectory(
            at: src, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "md" }

        for file in files {
            let dest = dst.appendingPathComponent(file.lastPathComponent)

            // 사용자 커스텀 파일 보존:
            // 파일 첫 줄에 "term-mesh-managed" 마커가 있을 때만 덮어쓰기
            if fm.fileExists(atPath: dest.path) {
                if !isManagedFile(at: dest) {
                    logger.debug("Skipping user-customized file: \(file.lastPathComponent, privacy: .public)")
                    continue
                }
            }

            // 번들 파일을 복사 (기존 managed 파일 덮어쓰기)
            // 임시 파일에 먼저 복사 후 rename으로 원자적 교체
            let tmp = dest.deletingLastPathComponent()
                .appendingPathComponent(".tmp-\(file.lastPathComponent)")
            try? fm.removeItem(at: tmp)
            try fm.copyItem(at: file, to: tmp)
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: tmp, to: dest)
            logger.debug("Installed: \(file.lastPathComponent, privacy: .public)")
        }
    }

    /// 파일 첫 줄에 "<!-- term-mesh-managed:" prefix 마커 확인.
    /// hasPrefix를 사용해 부정 주석(NOT term-mesh-managed 등)에 의한 오탐을 방지한다.
    private static func isManagedFile(at url: URL) -> Bool {
        guard let firstLine = (try? String(contentsOf: url, encoding: .utf8))?
            .components(separatedBy: .newlines).first else { return false }
        return firstLine.hasPrefix("<!-- term-mesh-managed:")
    }

    /// SKILL.md는 YAML frontmatter가 먼저 오므로, marker는 frontmatter 바로 다음 줄에 삽입된다.
    /// 파일 상단 30줄 이내에 "<!-- term-mesh-managed:" 가 있는지 확인한다.
    private static func isManagedSkillFile(at url: URL) -> Bool {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let headLines = content.components(separatedBy: .newlines).prefix(30)
        return headLines.contains { $0.hasPrefix("<!-- term-mesh-managed:") }
    }

    /// 스킬 설치. 각 스킬은 claude-skills/<name>/SKILL.md 구조로 번들에 있다.
    /// 디렉토리 단위로 순회하며, 기존에 같은 이름의 스킬이 있으면 managed 마커가 있을 때만 덮어쓴다.
    private static func installSkills(from src: URL, to dst: URL) throws {
        let fm = FileManager.default

        if !fm.fileExists(atPath: dst.path) {
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        }

        // 번들의 스킬 디렉토리 순회 (각각이 <name>/SKILL.md 구조)
        let skillDirs = try fm.contentsOfDirectory(
            at: src, includingPropertiesForKeys: [.isDirectoryKey]
        ).filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }

        for skillDir in skillDirs {
            let skillName = skillDir.lastPathComponent
            let srcFile = skillDir.appendingPathComponent("SKILL.md")
            guard fm.fileExists(atPath: srcFile.path) else {
                logger.debug("Skill \(skillName, privacy: .public): SKILL.md not found, skipping")
                continue
            }

            let destDir = dst.appendingPathComponent(skillName)
            let destFile = destDir.appendingPathComponent("SKILL.md")

            if fm.fileExists(atPath: destFile.path) {
                if !isManagedSkillFile(at: destFile) {
                    logger.debug("Skipping user-customized skill: \(skillName, privacy: .public)")
                    continue
                }
            } else {
                try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            }

            // 원자적 교체: 임시 파일에 쓴 뒤 rename
            let tmp = destDir.appendingPathComponent(".tmp-SKILL.md")
            try? fm.removeItem(at: tmp)
            try fm.copyItem(at: srcFile, to: tmp)
            try? fm.removeItem(at: destFile)
            try fm.moveItem(at: tmp, to: destFile)
            logger.debug("Installed skill: \(skillName, privacy: .public)")
        }
    }

    /// SemVer 비교: a가 b보다 새로우면 true
    private static func isNewer(_ a: String, than b: String) -> Bool {
        if b.isEmpty { return true }
        let toInts = { (s: String) in s.split(separator: ".").compactMap { Int($0) } }
        let av = toInts(a), bv = toInts(b)
        for i in 0..<max(av.count, bv.count) {
            let ai = i < av.count ? av[i] : 0
            let bi = i < bv.count ? bv[i] : 0
            if ai != bi { return ai > bi }
        }
        return false
    }
}
