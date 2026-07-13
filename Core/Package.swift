// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

#if os(macOS)
let kanaKanjiConverterTraits: Set<Package.Dependency.Trait> = ["Zenzai"]
#else
// for testing in Ubuntu environment.
let kanaKanjiConverterTraits: Set<Package.Dependency.Trait> = []
#endif

var products: [Product] = [
    // Products define the executables and libraries a package produces, making them visible to other packages.
    .library(
        name: "Core",
        targets: ["Core"]
    )
]

var targets: [Target] = [
    .executableTarget(
        name: "git-info-generator"
    ),
    .plugin(
        name: "GitInfoPlugin",
        capability: .buildTool(),
        dependencies: [.target(name: "git-info-generator")]
    ),
    .target(
        name: "Core",
        dependencies: [
            .product(name: "SwiftUtils", package: "AzooKeyKanaKanjiConverter"),
            .product(name: "KanaKanjiConverterModuleWithDefaultDictionary", package: "AzooKeyKanaKanjiConverter"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "ZIPFoundation", package: "ZIPFoundation")
        ],
        swiftSettings: [.interoperabilityMode(.Cxx)],
        plugins: [
            .plugin(name: "GitInfoPlugin")
        ]
    ),
    .testTarget(
        name: "CoreTests",
        dependencies: [
            "Core",
            .product(name: "Crypto", package: "swift-crypto")
        ],
        resources: [.copy("Fixtures")],
        swiftSettings: [.interoperabilityMode(.Cxx)]
    )
]

#if os(macOS)
products.append(
    .executable(
        name: "ConverterServer",
        targets: ["ConverterServer"]
    )
)
targets.append(
    .executableTarget(
        name: "ConverterServer",
        dependencies: ["Core"],
        swiftSettings: [.interoperabilityMode(.Cxx)]
    )
)
#endif

let package = Package(
    name: "Core",
    platforms: [.macOS(.v13)],
    products: products,
    dependencies: [
        .package(url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter", revision: "bbef9d2d99a2e9e69ac3f7e2e07b08474de59a81", traits: kanaKanjiConverterTraits),
        .package(
            url: "https://github.com/apple/swift-crypto.git",
            revision: "95ba0316a9b733e92bb6b071255ff46263bbe7dc" // 3.15.1
        ),
        .package(
            url: "https://github.com/weichsel/ZIPFoundation.git",
            revision: "22787ffb59de99e5dc1fbfe80b19c97a904ad48d" // 0.9.20
        )
    ],
    targets: targets
)
