// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "RemoteCore", platforms: [.iOS(.v17), .macOS(.v13)], products: [.library(name: "RemoteCore", targets: ["RemoteCore"])], targets: [.target(name: "RemoteCore")])
