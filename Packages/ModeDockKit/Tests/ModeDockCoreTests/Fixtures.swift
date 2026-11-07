import DisplayKit
import Foundation

let builtin = Display(
    id: 1, identity: DisplayIdentity(vendor: 1552, model: 1, serial: 1),
    name: "Built-in", isBuiltin: true, isEnabled: true)
let external = Display(
    id: 5, identity: DisplayIdentity(vendor: 19501, model: 29046, serial: 42),
    name: "LS28", isBuiltin: false, isEnabled: true)
let tv = Display(
    id: 7, identity: DisplayIdentity(vendor: 4268, model: 3, serial: 0),
    name: "TV", isBuiltin: false, isEnabled: true)

func makeDefaults() -> UserDefaults {
    UserDefaults(suiteName: "ModeDockCoreTests-\(UUID().uuidString)") ?? .standard
}
