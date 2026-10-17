import SwiftUI
import Testing
@testable import TheExplorer

@MainActor
struct ThemeTests {
    @Test func systemFollowsMacOSAndTheRestAreFixed() {
        #expect(ThemeChoice.system.palette(systemIsDark: true) == .dark)
        #expect(ThemeChoice.system.palette(systemIsDark: false) == .light)
        #expect(ThemeChoice.midnight.palette(systemIsDark: false) == .midnight)
        #expect(ThemeChoice.light.palette(systemIsDark: true).isDark == false)
        #expect(Set(ThemeChoice.allCases.map(\.title)).count == ThemeChoice.allCases.count)
    }

    @Test func applyingAThemeChangesTheTokens() {
        let before = Theme.colors
        defer { Theme.apply(before) }
        Theme.apply(.light)
        #expect(Theme.background == ThemePalette.light.background)
        #expect(Theme.colorScheme == .light)
        Theme.apply(.midnight)
        #expect(Theme.surface == ThemePalette.midnight.surface)
        #expect(Theme.colorScheme == .dark)
    }
}
