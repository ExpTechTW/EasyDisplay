import Foundation
import os

/// `log stream --predicate 'subsystem == "io.github.yuyu1015.EazyDisplay"'`
let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "io.github.yuyu1015.EazyDisplay", category: "display")
