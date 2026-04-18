# terraform-github-repository-and-content

Terraform module that creates a GitHub repository and commits file content to it.

## Features

- **Optional repo creation** -- set `create_repository = false` to manage files in an existing repository.
- **Content as `map(string)`** -- pass `files = { "path/in/repo" = "content" }`. Works with inline strings, `file()`, `templatefile()`, or any expression that produces a string.
- **Directory tree from disk** -- set `files_dir = "${path.module}/content"` to push an entire local directory into the repo recursively.
- **Branch targeting** -- files land on the default branch unless you set `branch`, in which case the branch is created automatically.
- **Configurable default branch** -- set `default_branch` to any name (defaults to `main`).
- **Template repos** -- bootstrap from an existing GitHub template repository.

## Usage

### Push a local directory tree into a new repo

```hcl
module "repo" {
  source = "github.com/matt-FFFFFF/terraform-github-repository-and-content"

  name        = "my-app"
  description = "Application managed by Terraform"

  # All files under content/ are read recursively and committed to the repo.
  files_dir = "${path.module}/content"
}
```

### Inline content

```hcl
module "repo" {
  source = "github.com/matt-FFFFFF/terraform-github-repository-and-content"

  name = "my-service"

  files = {
    "README.md"   = "# my-service\n"
    "src/main.py" = file("${path.module}/src/main.py")
  }
}
```

### Add files to an existing repo

```hcl
module "codeowners" {
  source = "github.com/matt-FFFFFF/terraform-github-repository-and-content"

  create_repository = false
  name              = "existing-repo"

  files = {
    ".github/CODEOWNERS" = "* @my-org/platform-team\n"
  }
}
```

### Commit to a feature branch

```hcl
module "repo" {
  source = "github.com/matt-FFFFFF/terraform-github-repository-and-content"

  name   = "my-config"
  branch = "config-update"

  files = {
    "config.yaml" = yamlencode({ setting = true, level = 5 })
  }
}
```

### Create from a template repository

```hcl
module "repo" {
  source = "github.com/matt-FFFFFF/terraform-github-repository-and-content"

  name = "new-microservice"

  template = {
    owner      = "my-org"
    repository = "microservice-template"
  }
}
```
