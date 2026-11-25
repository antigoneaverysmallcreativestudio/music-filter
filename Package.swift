// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FiltreMusique",
    platforms: [.macOS(.v13)],
    products: [.library(name: "FiltreCore", targets: ["FiltreCore"])],
    targets: [
        .target(name: "FiltreCore"),
        .testTarget(name: "FiltreCoreTests", dependencies: ["FiltreCore"])
    ]
)
