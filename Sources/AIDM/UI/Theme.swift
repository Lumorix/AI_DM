import SwiftUI

// 视觉风格：暗色旧宅 + 泛黄纸张 + 朱砂红 + 黄铜
enum Theme {
    static let ink = Color(hex: 0x141116)
    static let ink2 = Color(hex: 0x1D1920)
    static let ink3 = Color(hex: 0x2A242D)
    static let ink4 = Color(hex: 0x352E38)
    static let line = Color(hex: 0x3A323D)
    static let paper = Color(hex: 0xEFE6D3)
    static let paper2 = Color(hex: 0xE2D6BD)
    static let paperInk = Color(hex: 0x2B2420)
    static let text = Color(hex: 0xE9E3D8)
    static let bright = Color(hex: 0xF6EEDF)
    static let muted = Color(hex: 0x9B9198)
    static let red = Color(hex: 0xB3343A)
    static let redSoft = Color(hex: 0xB3343A).opacity(0.2)
    static let rose = Color(hex: 0xF0B8BB)
    static let brass = Color(hex: 0xC9A35B)
    static let green = Color(hex: 0x6F9E74)
    static let mint = Color(hex: 0xBFE0C2)
    static let amber = Color(hex: 0xF0C9A0)
    static let steel = Color(hex: 0xC9D6E8)

    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Songti SC", size: size).weight(weight)
    }

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static var backdrop: some View {
        ZStack {
            ink
            RadialGradient(colors: [red.opacity(0.10), .clear], center: .topLeading, startRadius: 0, endRadius: 700)
            RadialGradient(colors: [brass.opacity(0.05), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 600)
        }
        .ignoresSafeArea()
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

// MARK: - 纸张

struct PaperBackground: View {
    var body: some View {
        ZStack {
            Theme.paper
            Canvas { ctx, size in
                var y: CGFloat = 27
                while y < size.height {
                    ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(0.04)))
                    y += 28
                }
            }
            LinearGradient(colors: [.white.opacity(0.25), .clear, Theme.paper2.opacity(0.35)], startPoint: .top, endPoint: .bottom)
        }
    }
}

extension View {
    func paperCard(accent: Bool = false, padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(Theme.paperInk)
            .background(PaperBackground())
            .overlay(alignment: .leading) { if accent { Rectangle().fill(Theme.red).frame(width: 4) } }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
    }

    func inkCard(padding: CGFloat = 16, radius: CGFloat = 14) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.ink2, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.line.opacity(0.8)))
    }
}

// MARK: - 小部件

struct Chip: View {
    enum Style { case plain, on, ok, warn, brass }
    let text: String
    var style: Style = .plain
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)) }
            Text(text)
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundStyle(fg)
        .background(bg, in: Capsule())
        .lineLimit(1)
    }

    private var fg: Color {
        switch style {
        case .plain: Theme.muted
        case .on: Theme.rose
        case .ok: Theme.mint
        case .warn: Theme.amber
        case .brass: Theme.brass
        }
    }

    private var bg: Color {
        switch style {
        case .plain: Theme.ink3
        case .on: Theme.redSoft
        case .ok: Theme.green.opacity(0.2)
        case .warn: Color.orange.opacity(0.15)
        case .brass: Theme.brass.opacity(0.14)
        }
    }
}

struct SectionLabel: View {
    let text: String
    var color: Color = Theme.muted
    init(_ text: String, color: Color = Theme.muted) { self.text = text; self.color = color }
    var body: some View {
        Text(text).font(.system(size: 11.5, weight: .semibold)).tracking(3).foregroundStyle(color)
    }
}

struct InkButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, danger }
    var kind: Kind = .secondary
    var large = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 15 : 13, weight: kind == .primary ? .semibold : .medium))
            .padding(.horizontal, large ? 20 : 12).padding(.vertical, large ? 11 : 6)
            .foregroundStyle(fg)
            .background(bg(configuration.isPressed), in: RoundedRectangle(cornerRadius: large ? 11 : 8))
            .overlay(RoundedRectangle(cornerRadius: large ? 11 : 8).strokeBorder(border))
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Rectangle())
    }

    private var fg: Color {
        switch kind {
        case .primary: .white
        case .danger: Theme.rose
        default: Theme.text
        }
    }

    private func bg(_ pressed: Bool) -> Color {
        switch kind {
        case .primary: pressed ? Color(hex: 0x9A2C31) : Theme.red
        case .secondary: pressed ? Theme.ink4 : Theme.ink3
        case .ghost: pressed ? Theme.ink3 : .clear
        case .danger: pressed ? Theme.red.opacity(0.3) : Theme.redSoft
        }
    }

    private var border: Color {
        switch kind {
        case .primary: Theme.red
        case .ghost: .clear
        case .danger: Theme.red.opacity(0.4)
        case .secondary: Theme.line
        }
    }
}

extension ButtonStyle where Self == InkButtonStyle {
    static var ink: InkButtonStyle { InkButtonStyle() }
    static var inkPrimary: InkButtonStyle { InkButtonStyle(kind: .primary) }
    static var inkGhost: InkButtonStyle { InkButtonStyle(kind: .ghost) }
    static var inkDanger: InkButtonStyle { InkButtonStyle(kind: .danger) }
    static func ink(_ kind: InkButtonStyle.Kind, large: Bool = false) -> InkButtonStyle { InkButtonStyle(kind: kind, large: large) }
}

/// 文本框外观
struct InkField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Theme.ink, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }
}

extension View {
    func inkField() -> some View { modifier(InkField()) }
}

/// 多行输入框
struct InkEditor: View {
    @Binding var text: String
    var placeholder = ""
    var minHeight: CGFloat = 64
    var font: Font = .system(size: 13)

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder).font(font).foregroundStyle(Theme.muted.opacity(0.7))
                    .padding(.horizontal, 9).padding(.vertical, 8).allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(font)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 4).padding(.vertical, 6)
        }
        .frame(minHeight: minHeight)
        .background(Theme.ink, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }
}

struct BlinkingCursor: View {
    @State private var on = true
    var body: some View {
        Text("▍").foregroundStyle(Theme.brass).opacity(on ? 1 : 0)
            .onAppear { withAnimation(.easeInOut(duration: 0.5).repeatForever()) { on.toggle() } }
    }
}

struct Spinner: View {
    var size: CGFloat = 12
    var body: some View { ProgressView().controlSize(.mini).frame(width: size, height: size) }
}

/// 倒计时（超时变红）
struct PhaseTimer: View {
    let game: Game
    var size: CGFloat = 22

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            if let r = game.remaining(at: ctx.date) {
                Text(fmtSeconds(r))
                    .font(Theme.serif(size).monospacedDigit())
                    .foregroundStyle(r < 0 ? Theme.red : Theme.paper)
                    .contentTransition(.numericText())
            }
        }
    }
}

// MARK: - 记录流

struct LogRow: View {
    let entry: LogEntry
    var large = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.who).font(.system(size: large ? 13 : 11)).foregroundStyle(Theme.muted)
            Text(entry.text)
                .font(bodyFont)
                .foregroundStyle(color)
                .lineSpacing(large ? 5 : 3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bodyFont: Font {
        let s: CGFloat = large ? 17 : 13.5
        switch entry.kind {
        case .narration, .reveal, .answer: return Theme.serif(s)
        case .system, .search: return .system(size: s - 2)
        default: return .system(size: s)
        }
    }

    private var color: Color {
        switch entry.kind {
        case .narration, .reveal, .answer: Color(hex: 0xF3EAD9)
        case .system, .search: Theme.muted
        case .clue: Theme.amber
        case .note: Theme.steel
        case .ask: Theme.brass
        }
    }
}

struct ClueCard: View {
    let clue: Clue
    var folder: URL? = nil
    var isPublic = false
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            HStack(alignment: .top) {
                Text(clue.title).font(Theme.serif(compact ? 14 : 17, .bold))
                Spacer(minLength: 4)
                if isPublic {
                    Text("已公开").font(.system(size: 10.5)).foregroundStyle(Theme.red)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.red))
                        .rotationEffect(.degrees(4))
                }
            }
            Text(clue.text).font(.system(size: compact ? 12.5 : 14)).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            if let img = clue.image, let folder, let ns = NSImage(contentsOf: folder.appendingPathComponent(img)) {
                Image(nsImage: ns).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 3))
            }
        }
        .paperCard(accent: true, padding: compact ? 11 : 16)
    }
}
