// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "TikjotKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TikjotDomain", targets: ["TikjotDomain"]),
        .library(name: "TikjotHolidays", targets: ["TikjotHolidays"]),
        .library(name: "TikjotPersistence", targets: ["TikjotPersistence"]),
        .library(name: "JiraKit", targets: ["JiraKit"]),
        .library(name: "SyncEngine", targets: ["SyncEngine"]),
        .library(name: "TikjotSuggestions", targets: ["TikjotSuggestions"]),
    ],
    dependencies: [
        .package(path: "../../Vendor/GRDB"),
    ],
    targets: [
        .target(name: "TikjotDomain"),
        .target(name: "TikjotHolidays", dependencies: ["TikjotDomain"], resources: [.process("Resources")]),
        .target(name: "TikjotPersistence", dependencies: ["TikjotDomain", .product(name: "GRDB", package: "GRDB")]),
        .target(name: "JiraKit", dependencies: ["TikjotDomain"]),
        .target(name: "SyncEngine", dependencies: ["TikjotDomain", "JiraKit", "TikjotPersistence"]),
        .target(name: "TikjotSuggestions", dependencies: ["TikjotDomain"]),
        .testTarget(name: "TikjotDomainTests", dependencies: ["TikjotDomain"]),
        .testTarget(name: "TikjotHolidaysTests", dependencies: ["TikjotHolidays"]),
        .testTarget(name: "TikjotPersistenceTests", dependencies: ["TikjotPersistence"]),
        .testTarget(name: "JiraKitTests", dependencies: ["JiraKit"], resources: [.copy("Fixtures")]),
        .testTarget(name: "SyncEngineTests", dependencies: ["SyncEngine"]),
        .testTarget(name: "TikjotSuggestionsTests", dependencies: ["TikjotSuggestions"]),
    ],
    swiftLanguageModes: [.v6]
)
