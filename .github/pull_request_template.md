## Description

<!-- Briefly describe the problem, motivation, and solution implemented in this PR. -->

## Related Issue

Fixes #
<!-- or -->
Relates to #

## Type of Change

- [ ] `feat`: New feature or infrastructure capability
- [ ] `fix`: Bug fix in automation, manifests, or networking
- [ ] `sec`: Security enhancement, firewall rule, or SELinux policy update
- [ ] `refactor`: Code change that neither fixes a bug nor adds a feature
- [ ] `perf`: Storage, etcd fsync, or network performance optimization
- [ ] `ci`: CI/CD, automation, or pre-flight tooling change
- [ ] `docs`: Documentation, runbook, or architecture updates

---

## Verification Performed

<!-- Detail the steps taken to verify these changes. Include commands run, testbeds used, or paste relevant log excerpts. -->

- **Pre-flight Audit:** <!-- e.g., make precheck, scripts/precheck.sh -->
- **OpenTofu Validation:** <!-- e.g., tofu fmt -check, tofu validate, tofu plan -->
- **Ansible Syntax / Idempotency:** <!-- e.g., ansible-playbook --syntax-check, make verify-bastion -->
- **Target Hypervisor / Testbed:** <!-- e.g., Dell Precision T5600, virsh net-list, virsh pool-list -->
- **Results / Output:**
  <!-- Paste relevant summary logs, test output, or execution excerpts -->

---

## Checklist before Merging

- [ ] Tests and pre-flight audit checks pass cleanly
- [ ] Runbooks and documentation updated if architecture or variables changed
- [ ] No secrets, pull-secrets, SSH private keys, or credentials introduced
- [ ] Subnet isolation and zero-collision model with existing hypervisor bridges preserved
- [ ] Low-latency NVMe caching policies (cache=none, io=threads) maintained
