import SwiftUI

struct Card<Content: View>: View {
    var title: String?
    var trailing: AnyView?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || trailing != nil {
                HStack {
                    if let title {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    trailing
                }
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// One of the big Noise Canceling / Ambient / Off buttons.
struct ModeTile: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .frame(height: 20)
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(
                isSelected ? Color.accentColor : Color.primary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct ToggleRow: View {
    let title: String
    var subtitle: String?
    let isOn: Bool
    let set: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: Binding(get: { isOn }, set: set))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

/// A label with a menu picker aligned to the trailing edge.
struct PickerRow<Value: Hashable>: View {
    let title: String
    let selection: Value
    let options: [Value]
    let name: (Value) -> String
    let set: (Value) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 8)
            Picker(title, selection: Binding(get: { selection }, set: set)) {
                ForEach(options, id: \.self) { Text(name($0)).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }
}

/// A vertical slider for one EQ band. Reports every step while dragging and commits on release.
struct BandSlider: View {
    let label: String
    let value: Int
    let range: ClosedRange<Int>
    let onChange: (_ value: Int, _ commit: Bool) -> Void

    private let knob: CGFloat = 14

    var body: some View {
        VStack(spacing: 4) {
            Text(value > 0 ? "+\(value)" : "\(value)")
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            GeometryReader { geometry in
                let width = geometry.size.width
                let knobY = y(for: value, height: geometry.size.height)
                let zeroY = y(for: 0, height: geometry.size.height)
                ZStack {
                    Capsule()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 4, height: geometry.size.height - knob)
                        .position(x: width / 2, y: geometry.size.height / 2)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 4, height: abs(knobY - zeroY))
                        .position(x: width / 2, y: (knobY + zeroY) / 2)
                    Circle()
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                        .frame(width: knob, height: knob)
                        .position(x: width / 2, y: knobY)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let newValue = self.value(at: drag.location.y, height: geometry.size.height)
                            if newValue != value { onChange(newValue, false) }
                        }
                        .onEnded { drag in
                            onChange(self.value(at: drag.location.y, height: geometry.size.height), true)
                        }
                )
            }
            .frame(height: 104)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel("\(label) band")
        .accessibilityValue("\(value)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(value + 1, range.upperBound), true)
            case .decrement: onChange(max(value - 1, range.lowerBound), true)
            @unknown default: break
            }
        }
    }

    private func y(for value: Int, height: CGFloat) -> CGFloat {
        let fraction = CGFloat(value - range.lowerBound) / CGFloat(range.upperBound - range.lowerBound)
        return knob / 2 + (1 - fraction) * (height - knob)
    }

    private func value(at y: CGFloat, height: CGFloat) -> Int {
        let fraction = 1 - (y - knob / 2) / max(height - knob, 1)
        let clamped = min(max(fraction, 0), 1)
        return range.lowerBound + Int((clamped * CGFloat(range.upperBound - range.lowerBound)).rounded())
    }
}

/// Integer slider that streams changes while dragging and commits when released.
struct StepSlider: View {
    let value: Int
    let range: ClosedRange<Int>
    let onChange: (_ value: Int, _ commit: Bool) -> Void

    var body: some View {
        Slider(
            value: Binding(
                get: { Double(value) },
                set: { onChange(Int($0.rounded()), false) }
            ),
            in: Double(range.lowerBound)...Double(range.upperBound),
            step: 1
        ) {
            EmptyView()
        } onEditingChanged: { editing in
            if !editing { onChange(value, true) }
        }
        .labelsHidden()
        .controlSize(.small)
    }
}
