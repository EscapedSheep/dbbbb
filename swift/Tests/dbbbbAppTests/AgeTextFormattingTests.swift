import Foundation
import Testing
@testable import dbbbbApp

/// The activity sheet's human-readable age formatting (ROADMAP M2 ⑨): the
/// largest two units, unknown/negative → "—".
struct AgeTextFormattingTests {
    @Test func nilAndNegativeAreUnknown() {
        #expect(DisplayFormatting.ageText(nil) == "—")
        #expect(DisplayFormatting.ageText(.seconds(-5)) == "—")
    }

    @Test func secondsBelowOneMinute() {
        #expect(DisplayFormatting.ageText(.zero) == "0s")
        #expect(DisplayFormatting.ageText(.seconds(59)) == "59s")
    }

    @Test func minutesAndSeconds() {
        #expect(DisplayFormatting.ageText(.seconds(60)) == "1m 0s")
        #expect(DisplayFormatting.ageText(.seconds(95)) == "1m 35s")
    }

    @Test func hoursAndMinutes() {
        #expect(DisplayFormatting.ageText(.seconds(3_600)) == "1h 0m")
        #expect(DisplayFormatting.ageText(.seconds(7_380)) == "2h 3m")
    }

    @Test func daysAndHours() {
        #expect(DisplayFormatting.ageText(.seconds(90_000)) == "1d 1h")
    }

    @Test func subSecondAgesRoundToSeconds() {
        #expect(DisplayFormatting.ageText(.milliseconds(1_500)) == "1s")
    }
}
