// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BioLabExplorer",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "BioLabExplorerCore", targets: ["BioLabExplorerCore"]),
        .executable(name: "BioLabExplorer", targets: ["BioLabExplorer"]),
        .executable(name: "BioLabExplorerChecks", targets: ["BioLabExplorerChecks"]),
        .executable(name: "BioLabExplorerPipeline", targets: ["BioLabExplorerPipeline"]),
        .executable(name: "BioLabExplorerStructureCheck", targets: ["BioLabExplorerStructureCheck"]),
        .executable(name: "BioLabExplorerAchievementReport", targets: ["BioLabExplorerAchievementReport"])
    ],
    targets: [
        .target(
            name: "BioLabExplorerCore",
            path: "Sources/BioLabExplorerCore"
        ),
        .executableTarget(
            name: "BioLabExplorer",
            dependencies: ["BioLabExplorerCore"],
            path: "Sources/BioLabExplorer"
        ),
        .executableTarget(
            name: "BioLabExplorerChecks",
            dependencies: ["BioLabExplorerCore"],
            path: "Sources/BioLabExplorerChecks"
        ),
        .executableTarget(
            name: "BioLabExplorerPipeline",
            dependencies: ["BioLabExplorerCore"],
            path: "Sources/BioLabExplorerPipeline"
        ),
        .executableTarget(
            name: "BioLabExplorerStructureCheck",
            dependencies: ["BioLabExplorerCore"],
            path: "Sources/BioLabExplorerStructureCheck"
        ),
        .executableTarget(
            name: "BioLabExplorerAchievementReport",
            dependencies: ["BioLabExplorerCore"],
            path: "Sources/BioLabExplorerAchievementReport"
        )
    ]
)
