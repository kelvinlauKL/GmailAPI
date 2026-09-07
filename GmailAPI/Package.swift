// swift-tools-version: 6.4

import PackageDescription

let package = Package(
  name: "GmailAPI",
  platforms: [.macOS(.v27)],
  products: [
    .library(name: "GmailAPI", targets: ["GmailAPI"]),
    .library(name: "GmailSync", targets: ["GmailSync"])
  ],
  targets: [
    .target(name: "GmailAPI"),
    .target(name: "GmailSync", dependencies: ["GmailAPI"]),
    .testTarget(name: "GmailAPITests", dependencies: ["GmailAPI"]),
    .testTarget(name: "GmailSyncTests", dependencies: ["GmailSync"])
  ],
  swiftLanguageModes: [.v6]
)
