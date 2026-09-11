## Description
<!-- Briefly explain WHAT this PR does and WHY. Link to any related issue. -->

Closes #<!-- issue number -->

---

## Type of Change
<!-- Check all that apply -->
- [ ] `feat` — New feature or enhancement
- [ ] `fix` — Bug fix
- [ ] `docs` — Documentation only
- [ ] `test` — Adding or updating tests
- [ ] `ci` — CI/CD pipeline changes
- [ ] `chore` — Maintenance, dependency updates
- [ ] `refactor` — Code refactor (no behavior change)

---

## Changes Made
<!-- List the files changed and a one-line description for each -->
- `file/path.py` — description
- `another/file.yaml` — description

---

## Testing Done
<!-- Describe how you tested this change -->
- [ ] `pytest application/test_app.py` — unit tests pass
- [ ] `pytest application/chaos_test.py` — chaos tests pass
- [ ] `helm lint ./helm/keda-demo --set ...` — Helm chart valid
- [ ] `terraform validate` — Terraform valid
- [ ] Tested manually (describe below)

```
# Paste relevant test output here
```

---

## Checklist
- [ ] PR title follows Conventional Commits: `type(scope): description`
- [ ] All CI checks pass (lint, test matrix, docker build)
- [ ] Documentation updated if behavior changed
- [ ] No hardcoded AWS account IDs, secrets, or credentials
- [ ] Commit messages are verbose and explain the WHY
