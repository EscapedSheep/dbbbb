import Foundation
import Testing
@testable import dbbbbApp

/// The statistics sheet's human-readable byte formatting (ROADMAP M2 ⑩):
/// 1024-based units, one decimal past KB, unknown → "—".
struct ByteTextFormattingTests {
    @Test func nilAndNegativeAreUnknown() {
        #expect(DisplayFormatting.byteText(nil) == "—")
        #expect(DisplayFormatting.byteText(-1) == "—")
    }

    @Test func bytesBelowOneKBStayRaw() {
        #expect(DisplayFormatting.byteText(0) == "0 B")
        #expect(DisplayFormatting.byteText(1) == "1 B")
        #expect(DisplayFormatting.byteText(1023) == "1023 B")
    }

    @Test func kilobytes() {
        #expect(DisplayFormatting.byteText(1_024) == "1.0 KB")
        #expect(DisplayFormatting.byteText(1_536) == "1.5 KB")
        #expect(DisplayFormatting.byteText(1_048_575) == "1024.0 KB")
    }

    @Test func megabytesAndGigabytes() {
        #expect(DisplayFormatting.byteText(1_048_576) == "1.0 MB")
        #expect(DisplayFormatting.byteText(1_572_864) == "1.5 MB")
        #expect(DisplayFormatting.byteText(1_073_741_824) == "1.0 GB")
        #expect(DisplayFormatting.byteText(12_884_901_888) == "12.0 GB")
    }

    @Test func terabytesCapTheUnitLadder() {
        #expect(DisplayFormatting.byteText(1_099_511_627_776) == "1.0 TB")
        // Beyond TB the value keeps growing in TB — no unbounded unit names.
        #expect(DisplayFormatting.byteText(2_199_023_255_552) == "2.0 TB")
    }
}
