import AppKit
import Foundation

enum FinderDirectoryResolver {
    static func frontWindowDirectory() -> URL? {
        let source = """
        tell application "Finder"
            if (count of Finder windows) is greater than 0 then
                return POSIX path of (target of front Finder window as alias)
            else
                return POSIX path of (path to desktop folder)
            end if
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return nil }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        guard errorInfo == nil,
              let path = result.stringValue,
              !path.isEmpty else {
            return nil
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let values = try? directory.resourceValues(forKeys: [.isDirectoryKey])
        return values?.isDirectory == true ? directory : nil
    }
}
