import Foundation

extension Foundation.Bundle {
    static let module: Bundle = {
        let mainPath = Bundle.main.bundleURL.appendingPathComponent("IndexStoreDB_ISDBTestSupport.bundle").path
        let buildPath = "/Users/pedroproenca/Documents/Projects/mutate4swift/.build-codex-crap-next/arm64-apple-macosx/debug/IndexStoreDB_ISDBTestSupport.bundle"

        let preferredBundle = Bundle(path: mainPath)

        guard let bundle = preferredBundle ?? Bundle(path: buildPath) else {
            // Users can write a function called fatalError themselves, we should be resilient against that.
            Swift.fatalError("could not load resource bundle: from \(mainPath) or \(buildPath)")
        }

        return bundle
    }()
}