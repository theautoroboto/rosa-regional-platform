# FedRAMP Compliance Documentation

This directory contains FedRAMP High compliance resources and reference materials for the ROSA Regional Platform.

## Contents

### fedramp_master_logic.csv

**Source:** NIST 800-53 Rev 5 FedRAMP High Baseline

**Format:** CSV with control IDs and baseline designations

**Structure:**

- Column 1: Control ID + Baseline Designation Information (e.g., `AC-01.a`, `SC-13`)
- Column 2: Requirement_Text - `X` indicates required for FedRAMP High baseline

**Total Controls:** 699+ controls marked with "X" for FedRAMP High compliance

**Usage:**

This CSV is the authoritative source for determining which NIST 800-53 Rev 5 controls are required for FedRAMP High authorization. The `fedramp-compliance` agent uses this file to:

- Validate which controls apply to the platform
- Map infrastructure configurations to specific control requirements
- Generate compliance audit reports

**Reference:** [FedRAMP High Baseline (NIST 800-53 Rev 5)](https://www.fedramp.gov/assets/resources/documents/FedRAMP_Security_Controls_Baseline.xlsx)

## Compliance Audit Reports

Compliance audit reports are generated in this `docs/compliance/` directory with the naming convention:

```
fedramp-high-compliance-audit-YYYY-MM-DD.md
```

See [fedramp-high-compliance-audit-2026-03-25.md](fedramp-high-compliance-audit-2026-03-25.md) for the most recent audit.

## Related Documentation

- [CLAUDE.md](../../CLAUDE.md) - Project-wide instructions including security guidelines
- [AGENTS.md](../../AGENTS.md) - Agent definitions and usage
- [.claude/agents/fedramp-compliance.md](../../.claude/agents/fedramp-compliance.md) - FedRAMP compliance agent definition
