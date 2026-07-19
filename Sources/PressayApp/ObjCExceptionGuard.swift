import Foundation
import PressayObjCShim

/// Converts Objective-C NSExceptions into thrown Swift errors — an NSException
/// unwinding through Swift concurrency frames corrupts executor state and
/// crashes the process later at an unrelated point.
func catchingObjCException<T>(_ body: () throws -> T) throws -> T {
    var result: Result<T, Error>?
    if let nsError = LFCatchException({ result = Result { try body() } }) {
        throw nsError
    }
    return try result!.get()
}
