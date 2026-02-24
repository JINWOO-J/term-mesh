use git2::Repository;
use serde::{Deserialize, Serialize};

use uuid::Uuid;

#[derive(Debug, Deserialize)]
pub struct CreateParams {
    /// Path to the source git repository
    pub repo_path: String,
    /// Optional custom branch name (defaults to generated UUID-based name)
    pub branch: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct WorktreeInfo {
    pub name: String,
    pub path: String,
    pub branch: String,
}

/// Create a new git worktree sandbox for an agent session.
///
/// Worktrees are created at `../term-mesh_wt_<UUID>` relative to the repo,
/// matching the PRD spec (F-01).
pub fn create(params: serde_json::Value) -> Result<WorktreeInfo, String> {
    let params: CreateParams =
        serde_json::from_value(params).map_err(|e| format!("invalid params: {e}"))?;

    let repo = Repository::open(&params.repo_path)
        .map_err(|e| format!("cannot open repo at {}: {e}", params.repo_path))?;

    let short_id = &Uuid::new_v4().to_string()[..8];
    let wt_name = format!("term-mesh_wt_{short_id}");

    let branch_name = params
        .branch
        .unwrap_or_else(|| format!("term-mesh/{short_id}"));

    // Resolve HEAD to create the branch
    let head = repo
        .head()
        .map_err(|e| format!("cannot resolve HEAD: {e}"))?;
    let commit = head
        .peel_to_commit()
        .map_err(|e| format!("HEAD is not a commit: {e}"))?;

    // Create branch
    repo.branch(&branch_name, &commit, false)
        .map_err(|e| format!("cannot create branch '{branch_name}': {e}"))?;

    // Worktree path: sibling directory to the repo
    let repo_root = repo
        .workdir()
        .ok_or("bare repos not supported")?;
    let parent = repo_root
        .parent()
        .ok_or("repo has no parent directory")?;
    let wt_path = parent.join(&wt_name);

    // Create worktree
    repo.worktree(
        &wt_name,
        &wt_path,
        Some(
            git2::WorktreeAddOptions::new()
                .reference(Some(&repo.find_branch(&branch_name, git2::BranchType::Local)
                    .map_err(|e| format!("branch lookup failed: {e}"))?
                    .into_reference())),
        ),
    )
    .map_err(|e| format!("cannot create worktree: {e}"))?;

    tracing::info!("created worktree {wt_name} at {}", wt_path.display());

    Ok(WorktreeInfo {
        name: wt_name,
        path: wt_path.to_string_lossy().into_owned(),
        branch: branch_name,
    })
}

/// Remove a worktree by name.
pub fn remove(params: serde_json::Value) -> Result<(), String> {
    #[derive(Deserialize)]
    struct RemoveParams {
        repo_path: String,
        name: String,
    }

    let params: RemoveParams =
        serde_json::from_value(params).map_err(|e| format!("invalid params: {e}"))?;

    let repo = Repository::open(&params.repo_path)
        .map_err(|e| format!("cannot open repo: {e}"))?;

    // Find and prune the worktree
    let wt = repo
        .find_worktree(&params.name)
        .map_err(|e| format!("worktree '{}' not found: {e}", params.name))?;

    wt.prune(Some(
        git2::WorktreePruneOptions::new()
            .working_tree(true)
            .valid(true),
    ))
    .map_err(|e| format!("cannot prune worktree: {e}"))?;

    // Also remove the directory
    let repo_root = repo.workdir().ok_or("bare repos not supported")?;
    let parent = repo_root.parent().ok_or("repo has no parent directory")?;
    let wt_path = parent.join(&params.name);
    if wt_path.exists() {
        std::fs::remove_dir_all(&wt_path)
            .map_err(|e| format!("cannot remove directory: {e}"))?;
    }

    tracing::info!("removed worktree {}", params.name);
    Ok(())
}

/// List all term-mesh worktrees for a repo.
pub fn list(params: serde_json::Value) -> Result<Vec<WorktreeInfo>, String> {
    #[derive(Deserialize)]
    struct ListParams {
        repo_path: String,
    }

    let params: ListParams =
        serde_json::from_value(params).map_err(|e| format!("invalid params: {e}"))?;

    let repo = Repository::open(&params.repo_path)
        .map_err(|e| format!("cannot open repo: {e}"))?;

    let names = repo
        .worktrees()
        .map_err(|e| format!("cannot list worktrees: {e}"))?;

    let mut result = Vec::new();
    for name in names.iter().flatten() {
        if !name.starts_with("term-mesh_wt_") {
            continue;
        }
        if let Ok(wt) = repo.find_worktree(name) {
            let path = wt.path().to_string_lossy().into_owned();
            // Try to determine the branch
            let branch = worktree_branch(&repo, name);
            result.push(WorktreeInfo {
                name: name.to_string(),
                path,
                branch,
            });
        }
    }

    Ok(result)
}

fn worktree_branch(repo: &Repository, wt_name: &str) -> String {
    // Open the worktree's repo to read its HEAD
    let repo_root = match repo.workdir() {
        Some(r) => r,
        None => return "unknown".into(),
    };
    let parent = match repo_root.parent() {
        Some(p) => p,
        None => return "unknown".into(),
    };
    let wt_path = parent.join(wt_name);
    match Repository::open(&wt_path) {
        Ok(wt_repo) => match wt_repo.head() {
            Ok(head) => head
                .shorthand()
                .unwrap_or("detached")
                .to_string(),
            Err(_) => "unknown".into(),
        },
        Err(_) => "unknown".into(),
    }
}
