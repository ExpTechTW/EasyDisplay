import Foundation
import os

/// `log stream --predicate 'subsystem == "io.github.yuyu1015.EasyDisplay"'`
let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "io.github.yuyu1015.EasyDisplay", category: "display")
