import CryptoKit
import Foundation

// generate_appcast only warns about a key mismatch. Fail the release instead of
// publishing an update that existing installations cannot authenticate.
final class Appcast: NSObject, XMLParserDelegate {
    var enclosures: [[String: String]] = []
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName == "enclosure" { enclosures.append(attributeDict) }
    }
}

struct VerificationError: LocalizedError {
    var errorDescription: String? { "The update signature does not match the app’s public key. Release stopped." }
}

do {
    guard CommandLine.arguments.count == 4 else { throw VerificationError() }
    let info = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])), format: nil) as? [String: Any]
    let feed = Appcast()
    let parser = XMLParser(data: try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
    parser.delegate = feed
    guard parser.parse(), feed.enclosures.count == 1,
          let encodedKey = info?["SUPublicEDKey"] as? String, let key = Data(base64Encoded: encodedKey),
          let encodedSignature = feed.enclosures.first?["sparkle:edSignature"],
          let signature = Data(base64Encoded: encodedSignature) else { throw VerificationError() }
    let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]), options: .mappedIfSafe)
    guard try Curve25519.Signing.PublicKey(rawRepresentation: key).isValidSignature(signature, for: archive)
    else { throw VerificationError() }
    print("Verified update signature against the app’s embedded public key.")
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
