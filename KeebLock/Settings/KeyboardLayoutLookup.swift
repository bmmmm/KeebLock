import Carbon
import Foundation

/// Translates a hardware keycode → the glyph the user's CURRENT input source
/// would print for that key. Wraps the Carbon `UCKeyTranslate` API so the
/// heatmap can label each tile with what the user actually sees on their
/// keycaps (Q on US-ANSI, but Y on QWERTZ German for keycode 6, etc.).
///
/// Tested for German (com.apple.keylayout.German) and U.S. (com.apple.keylayout.US).
/// Other QWERTY-derivatives (FR/IT/ES/PL/...) work because UCKeyTranslate is
/// universal — they just haven't been visually verified.
enum KeyboardLayoutLookup {

    /// Returns the printable label for `keycode` under `source`, or nil if the
    /// layout has no Unicode mapping for it (e.g. dead keys / function keys).
    static func translate(keycode: UInt16, source: TISInputSource) -> String? {
        guard let layoutDataRaw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataRaw).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) -> String? in
            guard let basePtr = rawBuf.baseAddress else { return nil }
            let layoutPtr = basePtr.assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKeyState: UInt32 = 0
            var actualLength = 0
            var unicodeString = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layoutPtr,
                keycode,
                UInt16(kUCKeyActionDisplay),
                0,                              // no shift/ctrl/etc. modifiers
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                4,
                &actualLength,
                &unicodeString
            )
            guard status == noErr, actualLength > 0 else { return nil }
            let s = String(utf16CodeUnits: unicodeString, count: actualLength)
            // Skip control chars (e.g. backspace returns a non-printable code).
            if let scalar = s.unicodeScalars.first, scalar.value < 0x20 { return nil }
            return s.uppercased()
        }
    }

}
