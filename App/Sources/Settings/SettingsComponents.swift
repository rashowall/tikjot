import AppKit
import SwiftUI
import TikjotDomain

// Settings building blocks (design "Settings · …"): a bold grey heading over a white box of rows,
// rows separated by hairlines; label (+ hint) on the left, one control on the right.

extension DS.F {
    /// `field/text` values in Settings (8h, 1 Jan 2026, 80 %).
    static let monoField = Font.system(size: 13, design: .monospaced)
    /// Section heading above a settings box.
    static let settingsHeading = Font.system(size: 12, weight: .bold)
    /// Dialog title (display face in the design).
    static let dialogTitle = Font.system(size: 18, weight: .bold)
}

/// Heading + box of rows. Rows are separated by 1 pt `border` lines automatically.
struct SettingsSection<C: View>: View {
    let title: String?
    @ViewBuilder let content: C

    init(title: String? = nil, @ViewBuilder content: () -> C) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(DS.F.settingsHeading).foregroundStyle(DS.C.text2)
                    .accessibilityAddTraits(.isHeader)
            }
            SettingsBox { content }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The white rounded box with hairline-separated children.
struct SettingsBox<C: View>: View {
    @ViewBuilder let content: C
    var body: some View {
        _VariadicView.Tree(DividedRows()) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.surface))
            .clipShape(RoundedRectangle(cornerRadius: DS.R.card))
            .overlay(RoundedRectangle(cornerRadius: DS.R.card).strokeBorder(DS.C.border, lineWidth: 1))
    }
}

private struct DividedRows: _VariadicView_MultiViewRoot {
    @ViewBuilder
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        VStack(spacing: 0) {
            ForEach(children) { child in
                child
                if child.id != last { Rectangle().fill(DS.C.border).frame(height: 1) }
            }
        }
    }
}

/// A settings row: label 13 medium (+ hint 11 tertiary) left, control right, 10/14 padding.
struct SettingsRow<C: View>: View {
    let label: String
    var hint: String?
    var labelColor: Color = DS.C.text
    var hintColor: Color = DS.C.text3
    /// Optional link after the hint ("Choose reminders…").
    var link: (title: String, action: () -> Void)?
    @ViewBuilder let control: C

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(DS.F.bodyMedium).foregroundStyle(labelColor)
                    .fixedSize(horizontal: false, vertical: true)
                if hint != nil || link != nil {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let hint {
                            Text(hint).font(DS.F.caption).foregroundStyle(hintColor).lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let link {
                            Button(link.title, action: link.action).buttonStyle(LinkButtonStyle()).font(DS.F.captionMedium).fixedSize()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

extension SettingsRow where C == EmptyView {
    init(label: String, hint: String? = nil, labelColor: Color = DS.C.text, hintColor: Color = DS.C.text3) {
        self.init(label: label, hint: hint, labelColor: labelColor, hintColor: hintColor, link: nil) { EmptyView() }
    }
}

/// A row that opens more ("2 days ›", "github.com ↗ ›"): the whole row is the button.
struct SettingsLinkRow: View {
    let label: String
    var hint: String?
    var value: String?
    var labelColor: Color = DS.C.text
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            SettingsRow(label: label, hint: hint, labelColor: labelColor) {
                HStack(spacing: 10) {
                    if let value { Text(value).font(.system(size: 12)).foregroundStyle(DS.C.text2).lineLimit(1).fixedSize() }
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.C.text3)
                }
            }
            .background(hover ? DS.C.surface2.opacity(0.6) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.rowPress)
        .onHover { hover = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// `switch`: 32×18 brand capsule, white knob; off = border-strong.
/// The only switch in tikjot (system `.switch` toggles are too big next to the design's controls): with a label it
/// sits at the right end of the row, label left — like a Settings row.
struct BrandSwitchStyle: ToggleStyle {
    var showsLabel = true
    @Environment(\.isEnabled) private var enabled
    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if showsLabel {
            HStack(alignment: .center, spacing: 12) {
                configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { configuration.isOn.toggle() } }
                    .accessibilityHidden(true)
                knob(configuration)
            }
        } else {
            knob(configuration)
        }
    }

    private func knob(_ configuration: Configuration) -> some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { configuration.isOn.toggle() } } label: {
            Capsule()
                .fill(configuration.isOn ? DS.C.brand : DS.C.borderStrong)
                .frame(width: 32, height: 18)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(Color.white).frame(width: 14, height: 14)
                        .shadow(color: Color.black.opacity(0.25), radius: 1, y: 1)
                        .padding(2)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.chip)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

extension ToggleStyle where Self == BrandSwitchStyle {
    static var brandSwitch: BrandSwitchStyle { BrandSwitchStyle() }
}

/// A switch bound to a settings value.
struct SettingsSwitch: View {
    let label: String
    @Binding var isOn: Bool
    var body: some View { Toggle(label, isOn: $isOn).toggleStyle(BrandSwitchStyle(showsLabel: false)) }
}

/// Pop-up button (`Pop`): radius 7, border-strong outline, 12 medium, ⌃⌄ chevrons.
struct SettingsPopup<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]
    /// Shown after a separator (e.g. "None").
    var extra: [(T, String)] = []
    /// Label when the selection isn't among the options.
    var placeholder: String?

    var body: some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in item(o) }
            if !extra.isEmpty {
                Divider()
                ForEach(Array(extra.enumerated()), id: \.offset) { _, o in item(o) }
            }
        } label: {
            PopupLabel(text: (options + extra).first { $0.0 == selection }?.1 ?? placeholder ?? "")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder private func item(_ o: (T, String)) -> some View {
        Button { selection = o.0 } label: {
            if selection == o.0 { Label(o.1, systemImage: "checkmark") } else { Text(o.1) }
        }
    }
}

struct PopupLabel: View {
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(DS.C.text).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.C.text2)
        }
        .padding(.horizontal, 10)
        .frame(height: 25)
        .background(RoundedRectangle(cornerRadius: 7).fill(DS.C.surface))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(DS.C.borderStrong, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

/// `field/text` box with a date ("1 Jan 2026"); click → calendar.
struct DateFieldButton: View {
    @Binding var date: LocalDate
    var width: CGFloat = 110
    var range: ClosedRange<Date>?
    @State private var open = false
    @State private var picked: LocalDate?

    var body: some View {
        Button { open.toggle() } label: {
            Text(Fmt.dayMonthYear(date)).font(DS.F.body.monospacedDigit()).foregroundStyle(DS.C.text).lineLimit(1)
                .padding(.horizontal, 10)
                .frame(width: width, height: DS.H.field, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: DS.R.field).fill(DS.C.surface))
                .overlay(RoundedRectangle(cornerRadius: DS.R.field).strokeBorder(open ? DS.C.focusRingStrong : DS.C.borderStrong, lineWidth: open ? 2 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.field)
        .surfacePopover(isPresented: $open, arrowEdge: .bottom) {
            // Picking closes the calendar; the date is set only once it is gone — a setter that opens a sheet
            // (Import history from) presented it over the open popover, which hid Settings and stuck (GitHub #1).
            DateCalendar(selected: date, range: range.map { LocalDate($0.lowerBound, calendar: .current)...LocalDate($0.upperBound, calendar: .current) }) {
                picked = $0
                open = false
            }
            .onDisappear {
                if let picked, picked != date { date = picked }
                picked = nil
            }
        }
        .accessibilityLabel(Fmt.dayMonthYear(date))
    }
}

/// Small number field with a unit ("5 days", "15 min", "80 %") and a mini stepper; typed numbers accepted.
struct NumberField: View {
    @Binding var value: Int
    var range: ClosedRange<Int>
    var step = 1
    var unit: String
    var width: CGFloat?
    @State private var text = ""
    @FocusState private var focused: Bool

    // Design number fields (YUe7l / E0evw): plain bordered field, mono 13, no stepper ("5 days", "3h");
    // ↑ ↓ still step the value.
    var body: some View {
        HStack(spacing: unit.count <= 1 ? 0 : 4) {
            TextField("", text: $text)
                .textFieldStyle(.plain).font(DS.F.monoField).foregroundStyle(DS.C.text)
                .multilineTextAlignment(.leading)
                .frame(width: CGFloat(max(1, text.count)) * 7.9 + 3)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, f in if !f { commit() } }
                .onKeyPress(.upArrow) { nudge(step); return .handled }
                .onKeyPress(.downArrow) { nudge(-step); return .handled }
            Text(unit).font(DS.F.monoField).foregroundStyle(DS.C.text).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(minWidth: width ?? 60, minHeight: DS.H.field, maxHeight: DS.H.field, alignment: .leading)
        .fixedSize(horizontal: width == nil, vertical: false)
        .background(RoundedRectangle(cornerRadius: DS.R.field).fill(DS.C.surface))
        .overlay(RoundedRectangle(cornerRadius: DS.R.field).strokeBorder(focused ? DS.C.focusRingStrong : DS.C.borderStrong, lineWidth: focused ? 2 : 1))
        .clickToFocus($focused)
        .onAppear { text = "\(value)" }
        .onChange(of: value) { _, v in if !focused { text = "\(v)" } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(unit)")
        .accessibilityAdjustableAction { d in nudge(d == .increment ? step : -step) }
    }

    private func nudge(_ d: Int) {
        value = min(max(value + d, range.lowerBound), range.upperBound)
        text = "\(value)"
    }

    private func commit() {
        if let v = Int(text.filter(\.isNumber)) { value = min(max(v, range.lowerBound), range.upperBound) }
        text = "\(value)"
    }
}

/// Plain text field in the `field/text` look, optional leading icon; 2 pt focus ring.
struct SettingsTextField: View {
    let placeholder: String
    @Binding var text: String
    var icon: String?
    var secure = false
    var mono = false
    var error = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.system(size: 12)).foregroundStyle(DS.C.text3).frame(width: 14) }
            Group {
                if secure { SecureField(placeholder, text: $text) } else { TextField(placeholder, text: $text) }
            }
            .textFieldStyle(.plain)
            .font(mono ? DS.F.monoField : DS.F.body)
            .focused($focused)
        }
        .padding(.horizontal, 10)
        .frame(height: DS.H.field)
        .background(RoundedRectangle(cornerRadius: DS.R.field).fill(DS.C.surface))
        .overlay(RoundedRectangle(cornerRadius: DS.R.field)
            .strokeBorder(error ? DS.C.danger : (focused ? DS.C.focusRingStrong : DS.C.borderStrong), lineWidth: error || focused ? 2 : 1))
        .clickToFocus($focused)
    }
}

/// Labelled field (label 11 semibold secondary above the box).
struct LabeledField<C: View>: View {
    let label: String
    @ViewBuilder let content: C
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.C.text2)
            content
        }
    }
}

/// `sync/badge`: soft pill, signal-coloured icon, text-primary label.
struct StatusBadge: View {
    let text: String
    let icon: String
    var iconColor: Color = DS.C.success
    var fill: Color = DS.C.successSoft
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(iconColor)
            Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(DS.C.text).lineLimit(1)
        }
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(Capsule().fill(fill))
        .fixedSize()
    }
}

/// Banner above the sections (notifications blocked, snapshot failed): icon, bold title, body, one action.
struct SettingsNotice: View {
    enum Kind { case warning, danger }
    let kind: Kind
    let icon: String
    let title: String
    let text: String
    let action: String
    var actionIcon: String?
    var primary = false
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 16, weight: .medium))
                .foregroundStyle(kind == .warning ? DS.C.warning : DS.C.danger)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.F.bodySemibold).foregroundStyle(DS.C.text)
                Text(text).font(.system(size: 12)).foregroundStyle(DS.C.text2).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: perform) {
                if let actionIcon { Label(action, systemImage: actionIcon) } else { Text(action) }
            }
            .buttonStyle(primary ? .primaryPill : .pill)
        }
        .padding(.vertical, 14).padding(.leading, 14).padding(.trailing, 14)
        .background(RoundedRectangle(cornerRadius: DS.R.card).fill(kind == .warning ? DS.C.warningSoft : DS.C.dangerSoft))
    }
}

/// Settings dialog (sheet): title 18 bold, message, body; grey footer band with the buttons on the right.
struct SettingsDialog<Content: View, Footer: View>: View {
    let title: String
    var message: String?
    var width: CGFloat = 460
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(DS.F.dialogTitle).foregroundStyle(DS.C.text).fixedSize(horizontal: false, vertical: true)
                if let message {
                    Text(message).font(DS.F.body).foregroundStyle(DS.C.text2).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            .padding(.horizontal, 22).padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) { footer }
                .padding(.horizontal, 22).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .background(DS.C.surface2)
                .overlay(alignment: .top) { Rectangle().fill(DS.C.border).frame(height: 1) }
        }
        .frame(width: width)
        .background(DS.C.surface)
    }
}

/// Grey well with label/value lines (import progress, succession preview).
struct FactsWell: View {
    let rows: [(String, String)]
    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack {
                    Text(r.0).font(DS.F.body).foregroundStyle(DS.C.text2)
                    Spacer(minLength: 12)
                    Text(r.1).font(DS.F.bodySemibold).foregroundStyle(DS.C.text).multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.surface2))
    }
}

/// Warning box inside a dialog.
struct DialogWarning: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 13, weight: .medium)).foregroundStyle(DS.C.warning)
            Text(text).font(DS.F.body).foregroundStyle(DS.C.text).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.R.row).fill(DS.C.warningSoft))
    }
}

/// Sets the hosting window's title (Window menu, Mission Control) while the custom title bar draws its own.
struct WindowTitle: NSViewRepresentable {
    let title: String
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { v.window?.title = title }
    }
}
