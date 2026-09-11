---
name: Bug Report
about: Something isn't working as expected
title: "fix: "
labels: bug
assignees: ''
---

## What happened?
<!-- Describe the bug clearly. What did you expect vs what actually occurred? -->

**Expected:** 
**Actual:** 

---

## Steps to Reproduce
1. 
2. 
3. 

---

## Environment
- **EKS Version:** <!-- kubectl version --short -->
- **KEDA Version:** <!-- helm list -n keda -->
- **Terraform Version:** <!-- terraform version -->
- **Python Version:** <!-- python --version -->
- **OS:** 

---

## Logs
<!-- Paste relevant kubectl logs, GitHub Actions output, or Terraform errors -->
```
# kubectl logs -n keda-demo -l app.kubernetes.io/name=keda-demo --tail=50
```

---

## Additional Context
<!-- Screenshots, metric graphs, or KEDA ScaledObject status -->
```
# kubectl describe scaledobject keda-demo-scaledobject -n keda-demo
```
