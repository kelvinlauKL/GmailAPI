// swift-tools-version: 6.4

import PackageDescription

let package = Package(
  name: "GmailAPI",
  platforms: [.macOS(.v27)],
  products: [
    .library(name: "GmailAPI", targets: ["GmailAPI"])
  ],
  targets: [
    .target(name: "GmailAPI"),
    .testTarget(name: "GmailAPITests", dependencies: ["GmailAPI"])
  ],
  swiftLanguageModes: [.v6]
)
