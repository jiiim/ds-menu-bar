// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import Foundation

extension FileManager {
    /// FileManager's readability and executability checks also succeed for
    /// directories. Resolve symlinks before checking the item type so model
    /// and executable preflights accept links to files but reject directories.
    func isReadableRegularFile(atPath path: String) -> Bool {
        isReadableFile(atPath: path) && isRegularFile(atPath: path)
    }

    func isExecutableRegularFile(atPath path: String) -> Bool {
        isExecutableFile(atPath: path) && isRegularFile(atPath: path)
    }

    private func isRegularFile(atPath path: String) -> Bool {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
}
