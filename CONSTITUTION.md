# Mutate4Swift Project Constitution

## Purpose
`mutate4swift` exists to measure and improve test effectiveness by introducing realistic, behavior-changing mutations and verifying that tests detect them.

## First Principles
1. Mutate behavior, not formatting: every mutator must represent a plausible developer defect.
2. Prefer compilable mutants: build-breaking mutants are allowed but must be tracked and budgeted.
3. Isolate change: each mutant applies one intentional semantic edit.
4. Run meaningful tests: mutation outcomes are only valid when at least one relevant test executes.
5. Preserve developer trust: source restoration must be deterministic even after interruption.
6. Optimize for actionable signal: survived mutants and high build-error ratio must be surfaced as failures.

## Guardrails
1. Baseline gate: mutation run must fail if baseline tests do not pass.
2. No-tests gate: mutation run must fail if baseline executes zero tests for the selected scope/filter.
3. Build-error budget: fail the run when build-error ratio exceeds configured threshold.
4. Restore guarantee: always restore the original file and clean backup artifacts.
5. Workspace safety: optionally require clean git working tree before mutation.
6. Scale efficiency: when mutating many files, reuse baseline timing for identical test scopes.
7. Dual-runner support: support SwiftPM and Xcode (`xcodebuild`) workflows.

## Non-goals / Don’ts
1. Do not treat mutation score as a standalone quality KPI.
2. Do not mutate generated/vendor/build artifacts by default.
3. Do not silently pass runs where zero tests execute.
4. Do not optimize for vanity percentages by excluding hard-to-test code without review.
5. Do not default to full-repo mutation on large apps in local developer loops.

## Readiness Definition (Large Apple Apps)
`mutate4swift` is considered 100% ready for large iOS/iPadOS/macOS repositories when:
1. It can execute mutation runs in both SwiftPM and Xcode test environments.
2. It enforces baseline/no-tests/build-error guardrails.
3. It restores files safely after every run and after interrupted runs.
4. It provides human-readable and JSON reports with explicit outcome breakdowns.
5. It supports efficient batched mutation across many files without redundant baseline runs.
