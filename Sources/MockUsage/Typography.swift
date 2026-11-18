import SwiftUI

private struct UsageTextScaleKey: EnvironmentKey {
    static let defaultValue = 1.0
}

extension EnvironmentValues {
    var usageTextScale: Double {
        get { self[UsageTextScaleKey.self] }
        set { self[UsageTextScaleKey.self] = newValue }
    }
}

private struct UsageFont: ViewModifier {
    @Environment(\.usageTextScale) private var scale
    let style: Font.TextStyle
    let weight: Font.Weight
    let design: Font.Design
    private var points: CGFloat {
        switch style {
        case .largeTitle: return 26
        case .title: return 22
        case .title2: return 20
        case .title3: return 16
        case .headline: return 14
        case .caption, .caption2: return 11
        default: return 13
        }
    }
    func body(content: Content) -> some View {
        content.font(.system(size: points * scale, weight: weight, design: design))
    }
}

extension View {
    func usageFont(_ style: Font.TextStyle, weight: Font.Weight = .regular,
                   design: Font.Design = .default) -> some View {
        modifier(UsageFont(style: style, weight: weight, design: design))
    }
}
