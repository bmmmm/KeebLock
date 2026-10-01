import Foundation
import Security

/// Surfaces the Team ID + CDHash that the OS sees for this binary so the
/// launcher can show them next to the values published in the repo. The point
/// is not in-app verification — a tampered build could lie about its own
/// numbers — but to give the user one half of a side-by-side comparison.
/// The other half is `codesign -dv` against the on-disk binary, which the OS
/// performs and a tampered build cannot influence.
enum SigningIdentity {
    struct Info {
        let teamID: String?
        let cdHash: String?
    }

    static let current: Info = read()

    private static func read() -> Info {
        var dynCode: SecCode?
        guard SecCodeCopySelf([], &dynCode) == errSecSuccess, let dynCode else {
            return Info(teamID: nil, cdHash: nil)
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(dynCode, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return Info(teamID: nil, cdHash: nil)
        }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any] else {
            return Info(teamID: nil, cdHash: nil)
        }
        let teamID = dict[kSecCodeInfoTeamIdentifier as String] as? String
        let cdHash = (dict[kSecCodeInfoUnique as String] as? Data)
            .map { $0.map { String(format: "%02x", $0) }.joined() }
        return Info(teamID: teamID, cdHash: cdHash)
    }
}
