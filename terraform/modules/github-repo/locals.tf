locals {
  target_branch = var.branch != null && var.branch != var.default_branch ? github_branch.target[0].branch : (var.create_repository ? github_branch_default.this[0].branch : var.default_branch)
  repository    = var.create_repository ? github_repository.this[0].name : var.name

  # Resolve the effective files map: either the explicit files map or a
  # directory tree read from disk via files_dir.
  files = var.files_dir != null ? {
    for f in fileset(var.files_dir, "**") :
    f => file("${var.files_dir}/${f}")
  } : var.files
}
