import SwiftUI
import TikjotDomain

/// "What's a token and how do I get one?" — short, step by step, per Jira kind.
struct TokenHelp: View {
    let kind: JiraKind
    let usePassword: Bool
    let siteURL: URL?
    @State var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "questionmark.circle").foregroundStyle(DS.C.brand)
                    Text(kind == .cloud ? String(localized: "What's an API token and how do I get one?") : String(localized: "What's a personal access token and how do I get one?"))
                        .font(DS.F.captionMedium).foregroundStyle(DS.C.brandText)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(DS.C.brandText)
                }
            }
            .buttonStyle(LinkButtonStyle())
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(kind == .cloud
                         ? String(localized: "A token is a password just for apps. tikjot uses it to read your tasks and write your worklogs as you. You can revoke it any time without changing your Atlassian password.")
                         : String(localized: "A personal access token (PAT) is a password just for apps. tikjot uses it to read your tasks and write your worklogs as you. You can revoke it any time without changing your Jira password."))
                        .font(DS.F.caption).foregroundStyle(DS.C.text2).fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(i + 1)").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.C.onBrand)
                                .frame(width: 16, height: 16).background(Circle().fill(DS.C.brand))
                            Text(s).font(DS.F.caption).foregroundStyle(DS.C.text).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let url = openURL {
                        Button { NSWorkspace.shared.open(url) } label: {
                            Label(kind == .cloud ? String(localized: "Open Atlassian API tokens") : String(localized: "Open your Jira profile"), systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.pill(.secondary, height: DS.H.small))
                    }
                    if kind == .dataCenter && !usePassword {
                        Text(String(localized: "Don't see “Personal Access Tokens” in your profile? Your Jira is older than 8.14 or your admin turned them off — tick “use username and password” below."))
                            .font(DS.F.caption).foregroundStyle(DS.C.text2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: DS.R.card).fill(DS.C.brandSoft.opacity(0.5)))
            }
        }
    }

    private var openURL: URL? {
        kind == .cloud ? URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens") : siteURL?.appendingPathComponent("secure/ViewProfile.jspa")
    }

    private var steps: [String] {
        if kind == .cloud {
            return [
                String(localized: "Open Atlassian API tokens (button below) and sign in."),
                String(localized: "Click “Create API token”, name it “tikjot” and pick any expiry. When it runs out, tikjot tells you and you paste a new one."),
                String(localized: "Copy the token — Atlassian shows it only once — and paste it here with your Atlassian e-mail."),
            ]
        }
        if usePassword {
            return [
                String(localized: "Use the username and password you sign in to Jira with."),
                String(localized: "If your company uses single sign-on, ask your Jira admin to turn on personal access tokens instead."),
            ]
        }
        return [
            String(localized: "Open your Jira profile: your avatar (top right) › Profile."),
            String(localized: "Choose “Personal Access Tokens” › “Create token”, name it “tikjot”, set an expiry if you like."),
            String(localized: "Copy the token — Jira shows it only once — and paste it here."),
        ]
    }
}
