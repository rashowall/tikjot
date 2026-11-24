import SwiftUI
import TikjotDomain

/// What you chose in a project proposal list: names typed, rows left out, rows switched to not billable (by Jira key).
struct ProjectProposalChoices {
    var names: [String: String] = [:]
    var leftOut: Set<String> = []
    var notBillable: Set<String> = []

    /// Every row ticked, named after its Jira project (the key when the name isn't known).
    @MainActor init(items: [(UUID, String)], model: AppModel) {
        for (_, key) in items { names[key] = model.pendingProjectSuggestions[key]?.0 ?? key }
    }

    init() {}

    func included(_ items: [(UUID, String)]) -> Int { items.filter { !leftOut.contains($0.1) }.count }
}

/// The project proposal list (design c0J4w / jaSPm), the same in onboarding's Projects step and in Connect another
/// Jira step 2: one row per Jira project found in your worklogs — a checkbox (all on), the colour picked for you,
/// the name as a visibly editable field, the key, the hours imported and billable by a click. An unticked row is
/// muted and creates no project.
struct ProjectProposalList: View {
    @Environment(AppModel.self) private var model
    let items: [(UUID, String)]
    @Binding var choices: ProjectProposalChoices

    var body: some View {
        let colors = model.proposalColors(for: items)
        SettingsBox {
            ForEach(Array(items.enumerated()), id: \.element.1) { i, item in
                ProjectProposalRow(item: item, color: colors[i], choices: $choices)
            }
        }
    }
}

private struct ProjectProposalRow: View {
    @Environment(AppModel.self) private var model
    let item: (UUID, String)
    let color: String
    @Binding var choices: ProjectProposalChoices
    @State private var hovering = false
    @FocusState private var focused: Bool

    private var key: String { item.1 }

    var body: some View {
        let included = !choices.leftOut.contains(key)
        let billable = !choices.notBillable.contains(key)
        let secs = model.data.entries
            .filter { e in model.issue(for: e).map { $0.instanceId == item.0 && $0.projectKey == key } ?? false }
            .reduce(0) { $0 + $1.duration(now: model.now) }
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { included }, set: { v in
                if v { choices.leftOut.remove(key) } else { choices.leftOut.insert(key) }
            }))
            .toggleStyle(.checkbox).labelsHidden()
            .accessibilityLabel(String(localized: "Create a project for \(key)"))
            Circle().fill(DS.project(color)).frame(width: 10, height: 10).opacity(included ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 4) {
                nameField(included: included)
                HStack(spacing: 6) {
                    Text(key).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(DS.C.text2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(DS.C.surface2))
                    if secs > 0 { Text(String(localized: "\(DurationFormat.short(secs)) imported")).font(DS.F.caption).foregroundStyle(DS.C.text3) }
                    if !included {
                        Text(String(localized: "left out — entries keep their task, no project")).font(DS.F.caption).foregroundStyle(DS.C.text3)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { if billable { choices.notBillable.insert(key) } else { choices.notBillable.remove(key) } } label: {
                Text(billable ? String(localized: "Billable") : String(localized: "Not billable"))
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.C.text)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(billable ? DS.C.brandSoft : DS.C.surface2))
                    .contentShape(Capsule())
            }
            .buttonStyle(.chip)
            .help(String(localized: "Click to switch billable"))
            .disabled(!included).opacity(included ? 1 : 0.4)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .onHover { hovering = $0 }
    }

    /// Bordered like a field (not plain text), with a pencil on hover — so it reads as "you can rename this".
    private func nameField(included: Bool) -> some View {
        TextField(key, text: Binding(get: { choices.names[key] ?? key }, set: { choices.names[key] = $0 }))
            .textFieldStyle(.plain).font(DS.F.bodyMedium)
            .foregroundStyle(included ? DS.C.text : DS.C.text3)
            .focused($focused)
            .padding(.leading, 8).padding(.trailing, 24)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: DS.R.field).fill(included ? DS.C.surface : DS.C.surface2))
            .overlay(RoundedRectangle(cornerRadius: DS.R.field)
                .strokeBorder(focused ? DS.C.focusRingStrong : DS.C.borderStrong.opacity(included ? 1 : 0.5), lineWidth: focused ? 2 : 1))
            .overlay(alignment: .trailing) {
                Image(systemName: "pencil").font(.system(size: 11)).foregroundStyle(DS.C.text3)
                    .padding(.trailing, 8)
                    .opacity(included && (hovering || focused) ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: 280, alignment: .leading)
            .disabled(!included)
            .accessibilityLabel(String(localized: "Project name for \(key)"))
    }
}
