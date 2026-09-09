import Foundation
import Metal
import MetalKit
import UIKit
import Security

// Helper: log immediately
func aelog(_ msg: String) {
    NSLog("[AetherPS4] %@", msg)
    fflush(stdout)
    fflush(stderr)
}

// ── Entitlement + JIT-debug-state checking ──

private typealias SecTaskRef = OpaquePointer

@_silgen_name("SecTaskCopyValueForEntitlement")
private func SecTaskCopyValueForEntitlement(
    _ task: SecTaskRef,
    _ entitlement: NSString,
    _ error: NSErrorPointer
) -> CFTypeRef?

@_silgen_name("SecTaskCreateFromSelf")
private func SecTaskCreateFromSelf(_ allocator: CFAllocator?) -> SecTaskRef?

@_silgen_name("CFRelease")
private func aetherps4_CFRelease(_ cf: CFTypeRef?)

func checkAppEntitlement(_ ent: String) -> Bool {
    guard let task = SecTaskCreateFromSelf(nil) else { return false }
    defer { aetherps4_CFRelease(unsafeBitCast(task, to: CFTypeRef.self)) }

    guard let entitlement = SecTaskCopyValueForEntitlement(task, ent as NSString, nil) else { return false }

    if let number = entitlement as? NSNumber { return number.boolValue }
    if let bool = entitlement as? Bool { return bool }
    return false
}

private let AE_CS_DEBUGGED: Int32 = 0x10000000

@_silgen_name("csops")
private func aetherps4_csops(pid: Int32, ops: Int32, useraddr: UnsafeMutableRawPointer?, usersize: Int32) -> Int32

func checkDebugged() -> Bool {
    if checkAppEntitlement("dynamic-codesigning") { return true }
    var flags: Int32 = 0
    return aetherps4_csops(pid: getpid(), ops: 0, useraddr: &flags, usersize: Int32(MemoryLayout.size(ofValue: flags))) == 0
        && (flags & AE_CS_DEBUGGED) != 0
}

enum JITEnabler {
    static func requestStikDebugJIT() {
        guard let scriptData = script.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            aelog("JITEnabler: failed to percent-encode script")
            return
        }

        let target: String
        guard let bundleId = Bundle.main.bundleIdentifier else {
            aelog("JITEnabler: no bundle identifier, cannot request JIT")
            return
        }
        target = "bundle-id=\(bundleId)"

        // Back to the real StikDebug's own scheme (not the short-lived AetherDebug fork's
        // "aetherjit://"): `script` below is now a from-scratch minimal script covering only
        // the exact one command this app actually needs (see its header comment), rather than
        // an adapted copy of StikDebug's "universal" script -- and StikDebug already runs
        // whatever script is passed via script-data verbatim, on the real, unmodified app, so
        // there's no need to maintain and distribute a separate forked app just to change
        // which script runs.
        let urlScheme = "stikjit://enable-jit?\(target)&script-data=\(scriptData)"
        guard let url = URL(string: urlScheme) else {
            aelog("JITEnabler: failed to construct URL")
            return
        }
        aelog("JITEnabler: opening StikDebug with JIT26 script (\(script.count) chars, target=\(target))")
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    fileprivate static let script = """
Ly8gQWV0aGVyUFM0IG1pbmltYWwgSklUIHNjcmlwdC4KLy8KLy8gUHVycG9zZS1idWlsdCBmb3IgZXhhY3RseSB3aGF0IHRoaXMgYXBwIG5lZWRzIGFuZCBub3RoaW5nIGVsc2UsIHNvIGV2ZXJ5IGxpbmUgb2YgdGhpcwovLyBzY3JpcHQncyBsb2dpYyBjYW4gYmUgcmVhc29uZWQgYWJvdXQgZGlyZWN0bHkgcmF0aGVyIHRoYW4gdHJ1c3RpbmcgYW4gYWRhcHRlZCAidW5pdmVyc2FsIgovLyBzY3JpcHQncyBsZWdhY3kgYnJhbmNoZXMuIEFldGhlclBTNCdzIG93biBDKysgKHNyYy9jb3JlL2lvcy9pb3Nfaml0X2FsbG9jYXRvci5jcHAsCi8vIEZFWENvcmUncyBVdGlscy9BbGxvY2F0b3IuY3BwKSBpc3N1ZXMgQlJLICMweGYwMGQsIHgxNj0xIChKSVQyNlByZXBhcmVSZWdpb24gZXF1aXZhbGVudCkKLy8gcmVxdWVzdHMgaW4gZXhhY3RseSB0d28gc2hhcGVzLCBib3RoIGhhbmRsZWQgYmVsb3c6Ci8vICAgLSB4MCA9IDAsIHgxID0gc2l6ZTogYSBGUkVTSCBhbGxvY2F0aW9uIHJlcXVlc3QuIFBlciBpb3Nfaml0X2FsbG9jYXRvci5oJ3Mgb3duIHByb3RvY29sCi8vICAgICBkb2MsIHRoaXMgaXMgInRoZSBicmFuY2ggYWN0dWFsbHkgdXNlZCBoZXJlIiBieSBCT1RIIG9mIHRoaXMgY29kZWJhc2UncyBKSVQgYWxsb2NhdG9ycwovLyAgICAgKER1YWxNYXBwZWRSZWdpb246OkFsbG9jYXRlJ3Mgcnggc2lkZSwgYW5kIEZFWENvcmUncyBpT1NKSVRBbGxvYykgLS0gaS5lLiB0aGlzIGlzIHRoZQovLyAgICAgY29tbW9uIGNhc2UsIG5vdCBhbiBlZGdlIGNhc2UuCi8vICAgLSB4MCA9IGEgcmVhbCwgYWxyZWFkeS1hbGxvY2F0ZWQgYWRkcmVzcywgeDEgPSBpdHMgc2l6ZTogImdyYW50IGFuIGFkZHJlc3MgSSBhbHJlYWR5IG93biIuCi8vICAgICBpb3Nfaml0X2FsbG9jYXRvci5oIGRvY3VtZW50cyB0aGlzIGJyYW5jaCBhcyB0cmFjZWQgdG8gYSByZWFsLCByZXByb2R1Y2libGUgZXhlY3V0ZS0KLy8gICAgIHBlcm1pc3Npb24gZmFpbHVyZSBvbi1kZXZpY2UgYW5kIHNheXMgbm90IHRvIHVzZSBpdCBmb3IgbmV3IGNvZGUgLS0ga2VwdCBoZXJlIG9ubHkKLy8gICAgIGJlY2F1c2UgZWFybGllciByZXZpc2lvbnMgb2YgdGhpcyBzY3JpcHQgYXNzdW1lZCBpdCB3YXMgdGhlIG9ubHkgc2hhcGUgZXZlciBzZW50OyBhbgovLyAgICAgZWFybGllciB2ZXJzaW9uIG9mIHRoaXMgZmlsZSdzIG93biBoZWFkZXIgY29tbWVudCB3YXMgc2ltcGx5IHdyb25nIGFib3V0IHRoYXQuCi8vIEl0IG5ldmVyIHNlbmRzIGNvbW1hbmQgMCAoZGV0YWNoIC0tIElvc0ppdEFsbG9jYXRvcjo6RGV0YWNoKCkgZXhpc3RzIGJ1dCBpcyBuZXZlciBjYWxsZWQ7Ci8vIHNlZSB0aGF0IGhlYWRlcidzIG93biBkb2MgY29tbWVudCkgb3IgY29tbWFuZCAyIChkeW5hbWljIHNjcmlwdCBsb2FkaW5nIC0tIHRoaXMgc2NyaXB0IElTCi8vIHNlbnQgZGlyZWN0bHkgdmlhIHNjcmlwdC1kYXRhIG9uIGV2ZXJ5IGxhdW5jaCwgc28gdGhlcmUncyBub3RoaW5nIHRvIGxvYWQgYXQgcnVudGltZSkuCi8vCi8vIFRoZSBmcmVzaC1hbGxvY2F0aW9uIGJyYW5jaCAoeDAgPT0gMCkgbWlycm9ycyBTdGlrRGVidWcncyBvd24gcmVmZXJlbmNlIHVuaXZlcnNhbC5qcwovLyBKSVQyNlByZXBhcmVSZWdpb24gaGFuZGxlciB2ZXJiYXRpbSAoZ2l0aHViLmNvbS9TdGlrRGVidWcvU3Rpa0RlYnVnLAovLyBTdGlrRGVidWcvU2NyaXB0cy91bml2ZXJzYWwuanMpOiByZXF1ZXN0IGEgbmV3IFJYIHJlZ2lvbiBmcm9tIGRlYnVnc2VydmVyIGl0c2VsZiB2aWEgYQovLyBHREItcmVtb3RlICJfTTxsZW4+LHJ4IiBjb21tYW5kLCB0aGVuIHJ1biBwcmVwYXJlX21lbW9yeV9yZWdpb24gb24gVEhBVCBhZGRyZXNzIChub3Qgb24gdGhlCi8vIGxpdGVyYWwgMCB0aGUgZ3Vlc3Qgc2VudCksIGFuZCB3cml0ZSB0aGUgcmVhbCBhbGxvY2F0ZWQgYWRkcmVzcyBiYWNrIGludG8geDAgc28gdGhlIEMrKwovLyBjYWxsZXIgcmVjZWl2ZXMgaXQgYXMgQnJlYWtHZXRKSVRNYXBwaW5nJ3MgcmV0dXJuIHZhbHVlLiBBIHByaW9yIHZlcnNpb24gb2YgdGhpcyBzY3JpcHQKLy8gY2hlY2tlZCBvbmx5IGB4MCA9PSAwICYmIHgxID09IDBgIGFuZCBvdGhlcndpc2UgY2FsbGVkIHByZXBhcmVfbWVtb3J5X3JlZ2lvbih4MCwgeDEpCi8vIHVuY29uZGl0aW9uYWxseSAtLSB3aGljaCBmb3IgYSBnZW51aW5lIGZyZXNoLWFsbG9jYXRpb24gcmVxdWVzdCAoeDAgPT0gMCwgeDEgPT0gc2l6ZSwgc2l6ZQovLyAhPSAwKSBtZWFudCBjYWxsaW5nIHByZXBhcmVfbWVtb3J5X3JlZ2lvbigwLCBzaXplKTogYXR0ZW1wdGluZyB0byBncmFudCBleGVjdXRlIHBlcm1pc3Npb24KLy8gb24gdGhlIG51bGwgcGFnZSBpbnN0ZWFkIG9mIGFsbG9jYXRpbmcgYW55dGhpbmcsIGFuZCB3cml0aW5nIHgwIGJhY2sgYXMgMCAoQnJlYWtHZXRKSVRNYXBwaW5nCi8vIHJldHVybmluZyBudWxscHRyKSBldmVyeSBzaW5nbGUgdGltZS4gU2luY2UgYm90aCBvZiB0aGlzIGNvZGViYXNlJ3MgYWxsb2NhdG9ycyB1c2UgZXhhY3RseQovLyB0aGF0IHJlcXVlc3Qgc2hhcGUgZm9yIGV2ZXJ5IHJlYWwgSklUIGFsbG9jYXRpb24sIHRoaXMgd2FzIGEgdG90YWwsIHVuY29uZGl0aW9uYWwgZmFpbHVyZSBvZgovLyBKSVQgbWVtb3J5IGFsbG9jYXRpb24gdmlhIHRoaXMgc2NyaXB0IC0tIG5vdCBhIHJhcmUgZWRnZSBjYXNlLgoKZnVuY3Rpb24gbGl0dGxlRW5kaWFuSGV4U3RyaW5nVG9OdW1iZXIoaGV4U3RyKSB7CiAgICBjb25zdCBieXRlcyA9IFtdOwogICAgZm9yIChsZXQgaSA9IDA7IGkgPCBoZXhTdHIubGVuZ3RoOyBpICs9IDIpIHsKICAgICAgICBieXRlcy5wdXNoKHBhcnNlSW50KGhleFN0ci5zdWJzdHIoaSwgMiksIDE2KSk7CiAgICB9CiAgICBsZXQgbnVtID0gMG47CiAgICBmb3IgKGxldCBpID0gNDsgaSA+PSAwOyBpLS0pIHsKICAgICAgICBudW0gPSAobnVtIDw8IDhuKSB8IEJpZ0ludChieXRlc1tpXSk7CiAgICB9CiAgICByZXR1cm4gbnVtOwp9CgpmdW5jdGlvbiBudW1iZXJUb0xpdHRsZUVuZGlhbkhleFN0cmluZyhudW0pIHsKICAgIGNvbnN0IGJ5dGVzID0gW107CiAgICBmb3IgKGxldCBpID0gMDsgaSA8IDU7IGkrKykgewogICAgICAgIGJ5dGVzLnB1c2goTnVtYmVyKG51bSAmIDB4RkZuKSk7CiAgICAgICAgbnVtID4+PSA4bjsKICAgIH0KICAgIHdoaWxlIChieXRlcy5sZW5ndGggPCA4KSB7CiAgICAgICAgYnl0ZXMucHVzaCgwKTsKICAgIH0KICAgIHJldHVybiBieXRlcy5tYXAoYiA9PiBiLnRvU3RyaW5nKDE2KS5wYWRTdGFydCgyLCAnMCcpKS5qb2luKCcnKTsKfQoKZnVuY3Rpb24gbGl0dGxlRW5kaWFuSGV4VG9VMzIoaGV4U3RyKSB7CiAgICByZXR1cm4gcGFyc2VJbnQoaGV4U3RyLm1hdGNoKC8uLi9nKS5yZXZlcnNlKCkuam9pbignJyksIDE2KTsKfQoKZnVuY3Rpb24gZXh0cmFjdEJya0ltbWVkaWF0ZSh1MzIpIHsKICAgIHJldHVybiAodTMyID4+IDUpICYgMHhGRkZGOwp9Cgpjb25zdCBwaWQgPSBnZXRfcGlkKCk7CmNvbnN0IGF0dGFjaFJlc3BvbnNlID0gc2VuZF9jb21tYW5kKGB2QXR0YWNoOyR7cGlkLnRvU3RyaW5nKDE2KX1gKTsKbG9nKGBwaWQgPSAke3BpZH1gKTsKbG9nKGBhdHRhY2hfcmVzcG9uc2UgPSAke2F0dGFjaFJlc3BvbnNlfWApOwoKbGV0IHRvdGFsU2lnbmFscyA9IDA7CndoaWxlICh0cnVlKSB7CiAgICB0b3RhbFNpZ25hbHMrKzsKICAgIHRyeSB7CiAgICAgICAgaGFuZGxlT25lU2lnbmFsKCk7CiAgICB9IGNhdGNoIChlcnIpIHsKICAgICAgICAvLyBOZXZlciBsZXQgb25lIGJhZCBpdGVyYXRpb24gZW5kIHRoZSB3aG9sZSBzY3JpcHQncyBhYmlsaXR5IHRvIHNlcnZpY2UgZXZlcnkKICAgICAgICAvLyByZXF1ZXN0IGZvciB0aGUgcmVzdCBvZiB0aGUgc2Vzc2lvbiAtLSBsb2cgaXQgYW5kIGtlZXAgdGhlIGxvb3AgcnVubmluZy4KICAgICAgICBsb2coYFVuaGFuZGxlZCBleGNlcHRpb24gd2hpbGUgcHJvY2Vzc2luZyBzaWduYWwgJHt0b3RhbFNpZ25hbHN9OiAke2VyciAmJiBlcnIubmFtZX06ICR7ZXJyICYmIGVyci5tZXNzYWdlfWApOwogICAgICAgIGxvZyhlcnIgJiYgZXJyLnN0YWNrKTsKICAgIH0KfQoKZnVuY3Rpb24gaGFuZGxlT25lU2lnbmFsKCkgewogICAgY29uc3QgYnJrUmVzcG9uc2UgPSBzZW5kX2NvbW1hbmQoYGNgKTsKICAgIGxvZyhgYnJrUmVzcG9uc2UgPSAke2Jya1Jlc3BvbnNlfWApOwoKICAgIGxldCB0bXBNYXRjaCA9IC9UWzAtOWEtZl0rdGhyZWFkOig/PHRpZD5bMC05YS1mXSspOy8uZXhlYyhicmtSZXNwb25zZSk7CiAgICBjb25zdCB0aWQgPSB0bXBNYXRjaCA/IHRtcE1hdGNoLmdyb3Vwc1sndGlkJ10gOiBudWxsOwogICAgdG1wTWF0Y2ggPSAvMjA6KD88cmVnPlswLTlhLWZdezE2fSk7Ly5leGVjKGJya1Jlc3BvbnNlKTsKICAgIGxldCBwYyA9IHRtcE1hdGNoID8gdG1wTWF0Y2guZ3JvdXBzWydyZWcnXSA6IG51bGw7CiAgICB0bXBNYXRjaCA9IC8xMDooPzxyZWc+WzAtOWEtZl17MTZ9KTsvLmV4ZWMoYnJrUmVzcG9uc2UpOwogICAgbGV0IHgxNiA9IHRtcE1hdGNoID8gdG1wTWF0Y2guZ3JvdXBzWydyZWcnXSA6IG51bGw7CiAgICBpZiAoIXRpZCB8fCAhcGMgfHwgIXgxNikgewogICAgICAgIGxvZyhgRmFpbGVkIHRvIGV4dHJhY3QgcmVnaXN0ZXJzOiB0aWQ9JHt0aWR9LCBwYz0ke3BjfSwgeDE2PSR7eDE2fWApOwogICAgICAgIHJldHVybjsKICAgIH0KICAgIHBjID0gbGl0dGxlRW5kaWFuSGV4U3RyaW5nVG9OdW1iZXIocGMpOwogICAgeDE2ID0gbGl0dGxlRW5kaWFuSGV4U3RyaW5nVG9OdW1iZXIoeDE2KTsKCiAgICBjb25zdCBpbnN0cnVjdGlvblJlc3BvbnNlID0gc2VuZF9jb21tYW5kKGBtJHtwYy50b1N0cmluZygxNil9LDRgKTsKICAgIGNvbnN0IGluc3RyVTMyID0gbGl0dGxlRW5kaWFuSGV4VG9VMzIoaW5zdHJ1Y3Rpb25SZXNwb25zZSk7CgogICAgLy8gTm90IGEgQlJLIGluc3RydWN0aW9uIGF0IGFsbCAtLSBzb21lIG90aGVyIHNpZ25hbCBzdG9wcGVkIHRoaXMgdGhyZWFkLiBQYXNzIGl0IHRocm91Z2gKICAgIC8vIChyZS1kZWxpdmVyIHRoZSBzYW1lIHNpZ25hbCBudW1iZXIpIHNvIHRoZSBndWVzdCdzIG93biBoYW5kbGluZyAoaWYgYW55KSBzdGlsbCBydW5zLAogICAgLy8gdGhlbiBrZWVwIHRoZSBsb29wIGdvaW5nLgogICAgaWYgKCgoaW5zdHJVMzIgJiAweEZGRTAwMDFGKSA+Pj4gMCkgIT09IDB4RDQyMDAwMDApIHsKICAgICAgICBjb25zdCBzaWdudW1NYXRjaCA9IC9eVCg/PHNpZz5bYS16MC05O117Mn0pLy5leGVjKGJya1Jlc3BvbnNlKTsKICAgICAgICBjb25zdCBzaWdudW0gPSBzaWdudW1NYXRjaCA/IHNpZ251bU1hdGNoLmdyb3Vwc1snc2lnJ10gOiBudWxsOwogICAgICAgIGlmIChzaWdudW0pIHsKICAgICAgICAgICAgbG9nKGBOb3QgYSBCUksgKGluc3RydWN0aW9uIDB4JHtpbnN0clUzMi50b1N0cmluZygxNil9KTsgY29udGludWluZyB3aXRoIHNpZ25hbCAweCR7c2lnbnVtfWApOwogICAgICAgICAgICBzZW5kX2NvbW1hbmQoYHZDb250O1Mke3NpZ251bX06JHt0aWR9YCk7CiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgbG9nKGBOb3QgYSBCUksgKGluc3RydWN0aW9uIDB4JHtpbnN0clUzMi50b1N0cmluZygxNil9KTsgbm8gc2lnbmFsIG51bWJlciB0byBmb3J3YXJkYCk7CiAgICAgICAgfQogICAgICAgIHJldHVybjsKICAgIH0KCiAgICBjb25zdCBicmtJbW1lZGlhdGUgPSBleHRyYWN0QnJrSW1tZWRpYXRlKGluc3RyVTMyKTsKICAgIGlmIChicmtJbW1lZGlhdGUgIT09IDB4ZjAwZCkgewogICAgICAgIGxvZyhgSWdub3JpbmcgQlJLIGltbWVkaWF0ZSAweCR7YnJrSW1tZWRpYXRlLnRvU3RyaW5nKDE2KX0gKHRoaXMgc2NyaXB0IG9ubHkgaGFuZGxlcyAweGYwMGQpYCk7CiAgICAgICAgcmV0dXJuOwogICAgfQogICAgaWYgKHgxNiAhPT0gMW4pIHsKICAgICAgICBsb2coYElnbm9yaW5nIEpJVDI2IGNvbW1hbmQgJHt4MTYudG9TdHJpbmcoMTYpfSAodGhpcyBzY3JpcHQgb25seSBoYW5kbGVzIGNvbW1hbmQgMSwgcHJlcGFyZSByZWdpb24pYCk7CiAgICAgICAgcmV0dXJuOwogICAgfQoKICAgIHRtcE1hdGNoID0gLzAwOig/PHJlZz5bMC05YS1mXXsxNn0pOy8uZXhlYyhicmtSZXNwb25zZSk7CiAgICBsZXQgeDAgPSB0bXBNYXRjaCA/IHRtcE1hdGNoLmdyb3Vwc1sncmVnJ10gOiBudWxsOwogICAgdG1wTWF0Y2ggPSAvMDE6KD88cmVnPlswLTlhLWZdezE2fSk7Ly5leGVjKGJya1Jlc3BvbnNlKTsKICAgIGxldCB4MSA9IHRtcE1hdGNoID8gdG1wTWF0Y2guZ3JvdXBzWydyZWcnXSA6IG51bGw7CiAgICBpZiAoIXgwIHx8ICF4MSkgewogICAgICAgIGxvZyhgRmFpbGVkIHRvIGV4dHJhY3QgcmVnaXN0ZXJzOiB4MD0ke3gwfSwgeDE9JHt4MX1gKTsKICAgICAgICByZXR1cm47CiAgICB9CiAgICB4MCA9IGxpdHRsZUVuZGlhbkhleFN0cmluZ1RvTnVtYmVyKHgwKTsKICAgIHgxID0gbGl0dGxlRW5kaWFuSGV4U3RyaW5nVG9OdW1iZXIoeDEpOwoKICAgIC8vIFN0ZXAgcGFzdCB0aGUgYnJrIGluc3RydWN0aW9uIGl0c2VsZiBiZWZvcmUgZG9pbmcgYW55dGhpbmcgZWxzZSwgc2FtZSBhcyBldmVyeSBvdGhlcgogICAgLy8gY29tbWFuZCBoYW5kbGVyIGluIHRoaXMgcHJvdG9jb2wgLS0gb3RoZXJ3aXNlIHRoZSB0aHJlYWQgd291bGQgcmUtZXhlY3V0ZSB0aGUgc2FtZSBicmsKICAgIC8vIGluIGFuIGluZmluaXRlIGxvb3Agb25jZSByZXN1bWVkLgogICAgY29uc3QgcGNQbHVzNCA9IG51bWJlclRvTGl0dGxlRW5kaWFuSGV4U3RyaW5nKHBjICsgNG4pOwogICAgY29uc3QgcGNQbHVzNFJlc3BvbnNlID0gc2VuZF9jb21tYW5kKGBQMjA9JHtwY1BsdXM0fTt0aHJlYWQ6JHt0aWR9O2ApOwogICAgbG9nKGBwY1BsdXM0UmVzcG9uc2UgPSAke3BjUGx1czRSZXNwb25zZX1gKTsKCiAgICBpZiAoeDAgPT09IDBuICYmIHgxID09PSAwbikgewogICAgICAgIGxvZyhgcHJlcGFyZSByZWdpb24gcmVxdWVzdGVkIHdpdGggeDA9MCwgeDE9MCAtLSBub3RoaW5nIHRvIGRvYCk7CiAgICAgICAgcmV0dXJuOwogICAgfQoKICAgIC8vIEZJWDogZnJlc2gtYWxsb2NhdGlvbiBicmFuY2ggKHgwID09IDAsIHgxID09IHJlYWwgc2l6ZSkgLS0gbWlycm9ycyB1bml2ZXJzYWwuanMncwogICAgLy8gSklUMjZQcmVwYXJlUmVnaW9uIGV4YWN0bHkuIE1pc3NpbmcgdGhpcyBtZWFudCBldmVyeSByZWFsIGFsbG9jYXRpb24gZnJvbSB0aGlzCiAgICAvLyBjb2RlYmFzZSdzIG93biBKSVQgYWxsb2NhdG9ycyAod2hpY2ggYWx3YXlzIHNlbmQgeDA9MCBmb3IgYSBmcmVzaCByZWdpb24sIHBlcgogICAgLy8gaW9zX2ppdF9hbGxvY2F0b3IuaCkgZmVsbCB0aHJvdWdoIHRvIHByZXBhcmVfbWVtb3J5X3JlZ2lvbigwLCB4MSkgYmVsb3cgaW5zdGVhZC4KICAgIGxldCBqaXRQYWdlQWRkcmVzcyA9IHgwOwogICAgaWYgKHgwID09PSAwbikgewogICAgICAgIGNvbnN0IHJlcXVlc3RSWFJlc3BvbnNlID0gc2VuZF9jb21tYW5kKGBfTSR7eDEudG9TdHJpbmcoMTYpfSxyeGApOwogICAgICAgIGxvZyhgcmVxdWVzdFJYUmVzcG9uc2UgPSAke3JlcXVlc3RSWFJlc3BvbnNlfWApOwogICAgICAgIGlmICghcmVxdWVzdFJYUmVzcG9uc2UgfHwgcmVxdWVzdFJYUmVzcG9uc2UubGVuZ3RoID09PSAwKSB7CiAgICAgICAgICAgIGxvZyhgRmFpbGVkIHRvIGFsbG9jYXRlIFJYIG1lbW9yeSB2aWEgX00ke3gxLnRvU3RyaW5nKDE2KX0scnhgKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBqaXRQYWdlQWRkcmVzcyA9IEJpZ0ludChgMHgke3JlcXVlc3RSWFJlc3BvbnNlfWApOwogICAgICAgIGxvZyhgQWxsb2NhdGVkIEpJVCBwYWdlIGF0IGFkZHJlc3M6IDB4JHtqaXRQYWdlQWRkcmVzcy50b1N0cmluZygxNil9YCk7CiAgICB9CgogICAgY29uc3QgcHJlcGFyZVJlc3VsdCA9IHByZXBhcmVfbWVtb3J5X3JlZ2lvbihqaXRQYWdlQWRkcmVzcywgeDEpOwogICAgbG9nKGBwcmVwYXJlX21lbW9yeV9yZWdpb24oMHgke2ppdFBhZ2VBZGRyZXNzLnRvU3RyaW5nKDE2KX0sICR7eDF9KSA9ICR7cHJlcGFyZVJlc3VsdH1gKTsKCiAgICBjb25zdCBwdXRYMFJlc3BvbnNlID0gc2VuZF9jb21tYW5kKGBQMD0ke251bWJlclRvTGl0dGxlRW5kaWFuSGV4U3RyaW5nKGppdFBhZ2VBZGRyZXNzKX07dGhyZWFkOiR7dGlkfTtgKTsKICAgIGxvZyhgcHV0WDBSZXNwb25zZSA9ICR7cHV0WDBSZXNwb25zZX1gKTsKfQo=
"""
}

enum DeviceCpu {
    case mseries
    case aseries
}

struct ChipInfo {
    let series: DeviceCpu
    let number: Int
}

private extension FileManager {
    func filePath(atPath path: String, withLength length: Int) -> String? {
        guard let file = try? contentsOfDirectory(atPath: path).filter({ $0.count == length }).first else { return nil }
        return "\(path)/\(file)"
    }
}

extension ProcessInfo {
    var hasTXMClassic: Bool {
        ProcessInfo.processInfo.isiOSAppOnMac ? false :
        { if let boot = FileManager.default.filePath(atPath: "/System/Volumes/Preboot", withLength: 36), let file = FileManager.default.filePath(atPath: "\(boot)/boot", withLength: 96) { return access("\(file)/usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4", F_OK) == 0 } else { return (FileManager.default.filePath(atPath: "/private/preboot", withLength: 96).map { access("\($0)/usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4", F_OK) == 0 }) ?? false } }()
    }

    var hasTXM: Bool {
        if #available(iOS 27, *) {
            let lastNonTXM = 12 // A12
            let chipInfo = parseChipInfo()

            if let info = chipInfo, info.series == .aseries {
                return info.number > lastNonTXM
            }

            return true
        }

        if #available(iOS 26.6, *), !hasTXMClassic {
            let firstTXM = 15 // A15
            let iPadTXM = 2 // M2
            let chipInfo = parseChipInfo()

            if let info = chipInfo {
                if info.series == .mseries {
                    return info.number >= iPadTXM
                } else {
                    return info.number >= firstTXM
                }
            }

            return false
        }

        return hasTXMClassic
    }

    private func parseChipInfo() -> ChipInfo? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }

        let name = device.name.uppercased()

        if name.contains("APPLE M") {
            let numString = name.dropFirst("APPLE M".count).prefix(while: { $0.isNumber })
            if let number = Int(numString) {
                return ChipInfo(series: .mseries, number: number)
            }
        }

        if name.contains("APPLE A") {
            let numString = name.dropFirst("APPLE A".count).prefix(while: { $0.isNumber })
            if let number = Int(numString) {
                return ChipInfo(series: .aseries, number: number)
            }
        }

        return nil
    }
}

func configureJITEnvVars() {
    setenv("HAS_TXM", ProcessInfo.processInfo.hasTXM ? "1" : "0", 1)
    setenv("DUAL_MAPPED_JIT", "1", 1)
}
