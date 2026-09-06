// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "GmailAPI",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "GmailAPI", targets: ["GmailAPI"])
  ],
  targets: [
    .target(name: "GmailAPI"),
    .testTarget(name: "GmailAPITests", dependencies: ["GmailAPI"])
  ],
  swiftLanguageModes: [.v6]
)
