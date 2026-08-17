# Contributing to aws-keda-eks-autoscaling

Thank you for contributing! This document outlines our standards and conventions.

---

## Commit Message Convention

We follow **[Conventional Commits](https://www.conventionalcommits.org/)**:

```
<type>: <short description>

[optional body]

[optional footer]
```

### Allowed Types

| Type | When to Use |
|---|---|
| `feat` | A new feature or capability |
| `fix` | A bug fix |
| `docs` | Documentation only changes |
| `refactor` | Code restructuring (no behavior change) |
| `test` | Adding or updating tests |
| `chore` | Build system, tooling, or dependency updates |
| `perf` | Performance improvements |
| `ci` | CI/CD configuration changes |
| `build` | Build script changes |
| `release` | Version tags or release notes |
| `revert` | Reverting a previous commit |

### Examples

```bash
# Good ✅
git commit -m "feat: add SQS message batch processing support"
git commit -m "fix: handle SQS visibility timeout on processing failure"
git commit -m "docs: update ARCHITECTURE.md with IRSA trust policy details"

# Bad ❌
git commit -m "update stuff"
git commit -m "WIP"
git commit -m "Fixed the bug"
```

---

## Branching Strategy

```
main           ← production-ready, always deployable
  └── feat/day-N-<description>   ← daily feature branches
  └── fix/<issue-description>    ← bug fixes
  └── docs/<topic>               ← documentation updates
```

---

## Pre-commit Hooks

Install pre-commit before making contributions:

```bash
pip install pre-commit
pre-commit install
```

Hooks will run automatically on `git commit` and check:
- Python linting (ruff)
- YAML syntax (yamllint)
- Trailing whitespace
- Large file detection
- Private key detection
- Terraform formatting

---

## Pull Request Standards

- One logical change per PR
- All CI checks must pass
- Commit messages must follow Conventional Commits
- Include a description of what was changed and why
