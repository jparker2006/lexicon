import Foundation
import LexiconDomain

// Other manifest fields belong to eval policy and must not affect this local scan.
private struct GuardScanEntry: Decodable {
    let text: String?
}

func guardScan(_ manifest: URL) -> Int32 {
    do {
        let contents = try String(contentsOf: manifest, encoding: .utf8)
        let decoder = JSONDecoder()
        var scanned = 0
        var matched = 0
        for line in contents.components(separatedBy: "\n") where !line.allSatisfy(\.isWhitespace) {
            let entry = try decoder.decode(GuardScanEntry.self, from: Data(line.utf8))
            guard let text = entry.text else { continue }
            scanned += 1
            if SecretGuard.matches(text) { matched += 1 }
        }
        print("scanned=\(scanned) matched=\(matched)")
        return 0
    } catch {
        // File and decoding errors can contain private paths or manifest values.
        return fail("cannot scan manifest")
    }
}
