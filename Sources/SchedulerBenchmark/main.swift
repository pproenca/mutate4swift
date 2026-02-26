import Foundation
import MutationEngine

private struct Scenario {
    let name: String
    let jobs: Int
    let workloads: [MutationWorkload]
    let costModel: MutationSchedulerCostModel
}

private struct ScenarioSummary: Codable {
    let name: String
    let jobs: Int
    let runs: Int
    let staticMakespan: Double
    let dynamicMakespan: Double
    let speedup: Double
    let staticBaselines: Int
    let dynamicBaselines: Int
    let queueSteals: Int
    let deterministic: Bool
}

private struct ScenarioSamples {
    let staticMakespans: [Double]
    let dynamicMakespans: [Double]
    let staticBaselines: [Int]
    let dynamicBaselines: [Int]
    let queueSteals: [Int]
}

private enum OutputMode {
    case table
    case json
}

@main
struct SchedulerBenchmarkMain {
    static func main() async {
        do {
            let config = try parseArguments(CommandLine.arguments.dropFirst())
            let scenarios = makeScenarios(jobs: config.jobs)
            var summaries: [ScenarioSummary] = []
            summaries.reserveCapacity(scenarios.count)

            for scenario in scenarios {
                let summary = await runScenario(scenario, runs: config.runs)
                summaries.append(summary)
            }

            switch config.output {
            case .table:
                printTable(summaries)
            case .json:
                printJSON(summaries)
            }
        } catch {
            fputs("error: \(error)\n", stderr)
            exit(1)
        }
    }

    private struct Config {
        let runs: Int
        let jobs: Int
        let output: OutputMode
    }

    private static func parseArguments<S: Sequence>(_ args: S) throws -> Config where S.Element == String {
        var runs = 20
        var jobs = 4
        var output: OutputMode = .table

        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--runs":
                runs = try parsePositiveInt(iterator.next(), error: .invalidRuns)
            case "--jobs":
                jobs = try parsePositiveInt(iterator.next(), error: .invalidJobs)
            case "--json":
                output = .json
            case "--help":
                printUsage()
                exit(0)
            default:
                throw BenchmarkArgumentError.unknownArgument(arg)
            }
        }

        return Config(runs: runs, jobs: jobs, output: output)
    }

    private static func printUsage() {
        print(
            """
            Usage: SchedulerBenchmark [--runs N] [--jobs N] [--json]

            Runs deterministic scheduler benchmarks without invoking real Swift builds/tests.
            """
        )
    }

    private static func parsePositiveInt(
        _ value: String?,
        error: BenchmarkArgumentError
    ) throws -> Int {
        guard let value, let parsed = Int(value), parsed > 0 else {
            throw error
        }
        return parsed
    }

    private enum BenchmarkArgumentError: Error, CustomStringConvertible {
        case invalidRuns
        case invalidJobs
        case unknownArgument(String)

        var description: String {
            switch self {
            case .invalidRuns:
                return "--runs must be a positive integer"
            case .invalidJobs:
                return "--jobs must be a positive integer"
            case .unknownArgument(let arg):
                return "unknown argument: \(arg)"
            }
        }
    }

    private static func makeScenarios(jobs: Int) -> [Scenario] {
        [
            makeScopeAffinityBottleneckScenario(jobs: jobs),
            makeRuntimeSkewScenario(jobs: jobs),
            makeBalancedScenario(jobs: jobs),
        ]
    }

    private static func makeScopeAffinityBottleneckScenario(jobs: Int) -> Scenario {
        var workloads: [MutationWorkload] = []
        var costs: [String: Double] = [:]

        for index in 1...24 {
            let source = "/scenario/scope/File\(index).swift"
            let weight = 8 + (index % 5)
            workloads.append(
                MutationWorkload(
                    sourceFile: source,
                    scopeFilter: "FixtureTests",
                    potentialMutations: weight,
                    candidateMutations: weight
                )
            )
            costs[source] = Double(weight * 6)
        }

        return Scenario(
            name: "scope_affinity_bottleneck",
            jobs: jobs,
            workloads: workloads,
            costModel: MutationSchedulerCostModel(
                executionCostBySource: costs,
                baselineCostByScope: ["FixtureTests": 12],
                defaultExecutionCost: 1,
                defaultBaselineCost: 0
            )
        )
    }

    private static func makeRuntimeSkewScenario(jobs: Int) -> Scenario {
        var workloads: [MutationWorkload] = []
        var costs: [String: Double] = [:]
        let scopes = ["SlowTests", "FastTests", "FastTests", "FastTests"]

        for index in 1...20 {
            let scope = scopes[(index - 1) % scopes.count]
            let source = "/scenario/skew/File\(index).swift"
            let weight = 10
            workloads.append(
                MutationWorkload(
                    sourceFile: source,
                    scopeFilter: scope,
                    potentialMutations: weight,
                    candidateMutations: weight
                )
            )

            if scope == "SlowTests" {
                costs[source] = 120
            } else {
                costs[source] = 20
            }
        }

        return Scenario(
            name: "runtime_skew",
            jobs: jobs,
            workloads: workloads,
            costModel: MutationSchedulerCostModel(
                executionCostBySource: costs,
                baselineCostByScope: ["SlowTests": 10, "FastTests": 4],
                defaultExecutionCost: 1,
                defaultBaselineCost: 0
            )
        )
    }

    private static func makeBalancedScenario(jobs: Int) -> Scenario {
        var workloads: [MutationWorkload] = []
        var costs: [String: Double] = [:]

        for index in 1...24 {
            let scope = index % 2 == 0 ? "AlphaTests" : "BetaTests"
            let source = "/scenario/balanced/File\(index).swift"
            let weight = 10
            workloads.append(
                MutationWorkload(
                    sourceFile: source,
                    scopeFilter: scope,
                    potentialMutations: weight,
                    candidateMutations: weight
                )
            )
            costs[source] = 40
        }

        return Scenario(
            name: "balanced",
            jobs: jobs,
            workloads: workloads,
            costModel: MutationSchedulerCostModel(
                executionCostBySource: costs,
                baselineCostByScope: ["AlphaTests": 5, "BetaTests": 5],
                defaultExecutionCost: 1,
                defaultBaselineCost: 0
            )
        )
    }

    private static func runScenario(_ scenario: Scenario, runs: Int) async -> ScenarioSummary {
        let planner = MutationStrategyPlanner()
        let plan = planner.plan(workloads: scenario.workloads, jobs: scenario.jobs)
        let samples = await collectScenarioSamples(
            plan: plan,
            costModel: scenario.costModel,
            runs: runs
        )
        return makeScenarioSummary(scenario: scenario, runs: runs, samples: samples)
    }

    private static func collectScenarioSamples(
        plan: MutationStrategyPlan,
        costModel: MutationSchedulerCostModel,
        runs: Int
    ) async -> ScenarioSamples {
        var staticMakespans: [Double] = []
        var dynamicMakespans: [Double] = []
        var staticBaselines: [Int] = []
        var dynamicBaselines: [Int] = []
        var queueSteals: [Int] = []
        staticMakespans.reserveCapacity(runs)
        dynamicMakespans.reserveCapacity(runs)
        staticBaselines.reserveCapacity(runs)
        dynamicBaselines.reserveCapacity(runs)
        queueSteals.reserveCapacity(runs)

        for _ in 0..<runs {
            let comparison = await MutationSchedulerBenchmark.compare(
                plan: plan,
                costModel: costModel
            )
            staticMakespans.append(comparison.staticMetrics.makespan)
            dynamicMakespans.append(comparison.dynamicMetrics.makespan)
            staticBaselines.append(comparison.staticMetrics.baselineExecutions)
            dynamicBaselines.append(comparison.dynamicMetrics.baselineExecutions)
            queueSteals.append(comparison.dynamicMetrics.queueSteals)
        }

        return ScenarioSamples(
            staticMakespans: staticMakespans,
            dynamicMakespans: dynamicMakespans,
            staticBaselines: staticBaselines,
            dynamicBaselines: dynamicBaselines,
            queueSteals: queueSteals
        )
    }

    private static func makeScenarioSummary(
        scenario: Scenario,
        runs: Int,
        samples: ScenarioSamples
    ) -> ScenarioSummary {
        let staticMean = average(samples.staticMakespans)
        let dynamicMean = average(samples.dynamicMakespans)
        let deterministic = isScenarioDeterministic(samples)

        return ScenarioSummary(
            name: scenario.name,
            jobs: scenario.jobs,
            runs: runs,
            staticMakespan: staticMean,
            dynamicMakespan: dynamicMean,
            speedup: scenarioSpeedup(staticMakespan: staticMean, dynamicMakespan: dynamicMean),
            staticBaselines: samples.staticBaselines.first ?? 0,
            dynamicBaselines: samples.dynamicBaselines.first ?? 0,
            queueSteals: samples.queueSteals.first ?? 0,
            deterministic: deterministic
        )
    }

    private static func isScenarioDeterministic(_ samples: ScenarioSamples) -> Bool {
        isDeterministic(samples.staticMakespans)
            && isDeterministic(samples.dynamicMakespans)
            && isDeterministic(samples.staticBaselines)
            && isDeterministic(samples.dynamicBaselines)
            && isDeterministic(samples.queueSteals)
    }

    private static func scenarioSpeedup(staticMakespan: Double, dynamicMakespan: Double) -> Double {
        guard dynamicMakespan > 0 else {
            return 0
        }
        return staticMakespan / dynamicMakespan
    }

    private static func printTable(_ summaries: [ScenarioSummary]) {
        print("Deterministic Scheduler Benchmark")
        print("Scenarios: \(summaries.count)")
        print("")
        print("| Scenario | Static | Dynamic | Speedup | Static Baselines | Dynamic Baselines | Queue Steals | Deterministic |")
        print("|---|---:|---:|---:|---:|---:|---:|:---:|")
        for summary in summaries {
            print(
                "| \(summary.name) | \(fmt(summary.staticMakespan)) | \(fmt(summary.dynamicMakespan)) | "
                    + "\(fmt(summary.speedup))x | \(summary.staticBaselines) | \(summary.dynamicBaselines) | "
                    + "\(summary.queueSteals) | \(summary.deterministic ? "yes" : "no") |"
            )
        }
    }

    private static func printJSON(_ summaries: [ScenarioSummary]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(summaries) else {
            print("[]")
            return
        }
        print(String(decoding: data, as: UTF8.self))
    }

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func isDeterministic(_ values: [Double]) -> Bool {
        guard let first = values.first else { return true }
        return values.allSatisfy { abs($0 - first) < 0.000_001 }
    }

    private static func isDeterministic(_ values: [Int]) -> Bool {
        guard let first = values.first else { return true }
        return values.allSatisfy { $0 == first }
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
