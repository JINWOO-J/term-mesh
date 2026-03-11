import Foundation

/// Protocol abstracting TermMeshDaemon's public API for testability and decoupling.
protocol DaemonService: AnyObject {
    var worktreeEnabled: Bool { get }

    func startDaemon()
    func stopDaemon()

    func createWorktree(repoPath: String, branch: String?) -> WorktreeInfo?
    func createWorktreeWithError(repoPath: String, branch: String?) -> Result<WorktreeInfo, WorktreeCreateError>
    func findGitRoot(from path: String) -> String?
    func removeWorktree(repoPath: String, name: String) -> Bool
    func listWorktrees(repoPath: String) -> [WorktreeInfo]

    func trackPID(_ pid: Int32)
    func untrackPID(_ pid: Int32)
    func stopProcess(pid: Int32) -> Bool
    func resumeProcess(pid: Int32) -> Bool
}

extension TermMeshDaemon: DaemonService {}
