// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PalmCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "PalmCore", targets: ["PalmCore"])],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.21")
    ],
    targets: [
        .target(
            name: "CJPEGTurbo",
            sources: [
                "palm_jpeg.c",
                "libjpeg-turbo/src/wrapper",
                "libjpeg-turbo/src/jaricom.c", "libjpeg-turbo/src/jcomapi.c", "libjpeg-turbo/src/jdapimin.c",
                "libjpeg-turbo/src/jdarith.c", "libjpeg-turbo/src/jdatasrc.c", "libjpeg-turbo/src/jdhuff.c",
                "libjpeg-turbo/src/jdinput.c", "libjpeg-turbo/src/jdlhuff.c", "libjpeg-turbo/src/jdmarker.c",
                "libjpeg-turbo/src/jdmaster.c", "libjpeg-turbo/src/jdphuff.c", "libjpeg-turbo/src/jerror.c",
                "libjpeg-turbo/src/jmemmgr.c", "libjpeg-turbo/src/jmemnobs.c", "libjpeg-turbo/src/jpeg_nbits.c"
            ],
            cSettings: [.headerSearchPath("config"), .headerSearchPath("libjpeg-turbo/src"), .unsafeFlags(["-w"])]
        ),
        .target(name: "PalmCore", dependencies: ["ZIPFoundation", "CJPEGTurbo"]),
        .testTarget(name: "PalmCoreTests", dependencies: ["PalmCore"])
    ]
)
