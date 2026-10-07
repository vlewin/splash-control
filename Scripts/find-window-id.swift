import CoreGraphics
import Foundation

let args = CommandLine.arguments
let targetOwner = args.count > 1 ? args[1] : ""
let targetTitle = args.count > 2 ? args[2] : ""

guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
    exit(1)
}

for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    let title = w[kCGWindowName as String] as? String ?? ""
    let wid = w[kCGWindowNumber as String] as? Int ?? 0

    let ownerMatch = targetOwner.isEmpty || owner.localizedCaseInsensitiveContains(targetOwner)
    let titleMatch = targetTitle.isEmpty || title.localizedCaseInsensitiveContains(targetTitle)

    if ownerMatch && titleMatch && wid > 0 {
        print(wid)
        exit(0)
    }
}

exit(1)
