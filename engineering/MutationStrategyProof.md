# Mutation Strategy Proof Sketch

## Objective
Given a Swift package, we want a strategy that:
1. Finds test adequacy gaps (mutations that survive or lines that are not covered).
2. Preserves mutation-testing correctness guarantees (no silent pass when zero tests run).
3. Produces an execution plan that is as parallel as possible given available information.

## Required Data (First Principles)
1. Source mutation opportunities:
   - Generated from syntax (`MutationDiscoverer`) and equivalent-filtered (`EquivalentMutationFilter`).
2. Test scope candidates per source:
   - Derived from SwiftPM package graph (`swift package dump-package`) plus source/test naming conventions.
3. Covered source lines:
   - Derived from `swift test --enable-code-coverage` and `llvm-cov export`.
4. Workload weights:
   - Number of candidate mutations per source file after filters.

## What Swift Tools Provide
1. `swift package dump-package`:
   - Target graph and test-target dependencies.
2. `swift test --filter`:
   - Scoped test execution by target/test expression.
3. `swift test --enable-code-coverage` + `llvm-cov export`:
   - Covered line segments per file.

## Strategy Algorithm
1. For each source file:
   - Discover potential mutations.
   - Apply equivalent filtering.
   - Optionally apply coverage filtering.
   - Resolve test scope filter.
2. Build workloads:
   - `potentialMutations` and `candidateMutations` per file.
3. Mark uncovered risk:
   - `potentialMutations > 0 && candidateMutations == 0`.
4. Plan parallel buckets:
   - Use LPT (Longest Processing Time first) list scheduling on workload weights.

## Correctness Claims
1. Coverage-risk detection soundness:
   - If a file has potential mutations and coverage removes all candidates, the strategy marks it as uncovered.
   - This is by direct construction (`isUncovered` predicate).
2. Work preservation:
   - Every candidate workload is assigned to exactly one bucket.
   - LPT inserts each item once into exactly one minimum-load bucket.
3. Scope preservation:
   - Workloads keep their resolved scope filters; planner never widens or narrows a file scope.
4. Conservative fallback on missing coverage:
   - If coverage lookup fails, planner keeps candidate set unchanged.
   - This avoids false optimism from missing telemetry.

## Efficiency Claim
Let `m` be planned buckets and `W` total candidate mutation weight.
1. Lower bound on makespan: `LB = max(maxItemWeight, ceil(W/m))`.
2. LPT schedule makespan `Cmax` satisfies classical list-scheduling bounds.
3. Reported `estimatedSpeedupUpperBound = W / Cmax` is attainable only if runtime overhead is negligible.

## Complexity
Let:
- `F` = number of files
- `S` = total discovered mutation sites across files
- `m` = planned buckets
Then:
1. Site discovery and filtering: `O(S)`.
2. Sorting for LPT: `O(F log F)`.
3. Bucket assignment: `O(F * m)` (small `m` in practice).
Total: `O(S + F log F + Fm)`.

## Practical Implication
This planner gives a rigorous, data-driven strategy before mutation execution:
1. It identifies high-value files by candidate mutation count.
2. It identifies uncovered risk files explicitly.
3. It provides a parallelization blueprint with measurable lower/upper bounds.
