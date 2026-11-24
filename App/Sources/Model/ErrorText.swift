import Foundation
import JiraKit
import TikjotDomain

/// Localized plain-words reasons (§11.9). Jira's own validation texts are shown as Jira sent them.
extension JiraError {
    var display: String {
        switch self {
        case .offline: return String(localized: "Jira can't be reached. Check your connection or VPN.")
        case .unauthorized: return String(localized: "Jira signed you out — the token expired or was revoked.")
        case .forbidden(let m): return m.isEmpty ? String(localized: "You don't have permission to log work on this task.") : m
        case .notFound: return String(localized: "The task or worklog no longer exists in Jira.")
        case .rateLimited: return String(localized: "Jira asked us to slow down.")
        case .validation(let m): return m.isEmpty ? String(localized: "Jira rejected the worklog.") : m
        case .server(let c): return String(localized: "Jira had a problem (\(c)). It will be retried.")
        case .invalidResponse(let m): return String(localized: "Unexpected answer from Jira: \(m)")
        case .badURL: return String(localized: "The Jira address doesn't look right.")
        case .signInPage(let host):
            return host.isEmpty
                ? String(localized: "Jira answered with a company sign-in page instead of data — it isn't reachable from this network. Connect to your company VPN, or if you are, turn it off and on again.")
                : String(localized: "Jira answered with a company sign-in page (\(host)) instead of data — it isn't reachable from this network. Connect to your company VPN, or if you are, turn it off and on again.")
        case .outcomeUnknown: return String(localized: "Jira didn't answer in time. tikjot checks whether the worklog arrived before sending it again.")
        case .insecure: return String(localized: "tikjot connects to Jira only over https://. Use the https address of your Jira.")
        // Internal hosts resolve only through the VPN's DNS, so "not found" is usually the VPN, sometimes a typo.
        case .hostNotFound: return String(localized: "No server answers at this address. Check it — and if Jira is on your company network, connect to the VPN.")
        case .noAnswer: return String(localized: "The server doesn't answer. Are you connected to your company VPN? If you are, turn it off and on again.")
        case .untrustedCertificate: return String(localized: "This Mac doesn't trust your Jira's certificate. Your IT can fix it (company certificate in Keychain).")
        case .captcha: return String(localized: "Jira wants a check after failed sign-ins. Sign in once in your browser, then try again.")
        }
    }
}

/// The connect form's reason when Jira refused the details (by kind, method and what the server said).
extension JiraSignInProblem {
    var display: String {
        switch self {
        case .cloudNeedsAPIToken: return String(localized: "For Jira Cloud use your Atlassian account email and an API token — not your password.")
        case .tokenMismatch: return String(localized: "The token doesn't match. Create a personal access token in Jira: your profile › Personal Access Tokens.")
        case .wrongPassword: return String(localized: "Jira didn't accept these details. Check the email/username and token.")
        case .companySSO: return String(localized: "Your company signs in with Microsoft/Okta — a password won't work here. Use a personal access token.")
        }
    }
}

extension SyncErrorInfo {
    var display: String {
        switch code {
        case "offline": return JiraError.offline.display
        case "401": return JiraError.unauthorized.display
        case "404": return JiraError.notFound.display
        case "429": return JiraError.rateLimited(retryAfter: 0).display
        case "url": return JiraError.badURL.display
        case "sso": return JiraError.signInPage("").display
        case "unknown": return JiraError.outcomeUnknown.display
        case "http": return JiraError.insecure.display
        case "dns": return JiraError.hostNotFound.display
        case "noanswer": return JiraError.noAnswer.display
        case "cert": return JiraError.untrustedCertificate.display
        case "captcha": return JiraError.captcha.display
        default:
            if let c = Int(code), c >= 500 { return JiraError.server(c).display }
            return message
        }
    }
}
