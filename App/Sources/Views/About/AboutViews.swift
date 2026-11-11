import SwiftUI
import WaitingPawsCore

/// Version, the privacy policy and the open-source licenses (iOS Settings and the Mac «О приложении» pane).
enum AppInfo {
    /// "1.6.10 (9a8e796)": the version and the commit it was built from, the same on iPhone, Mac and Windows;
    /// "dev" for a build from Xcode.
    static var version: String {
        guard let release else { return "dev" }
        return "\(release.version) (\(release.commit))"
    }

    /// A build made by Tools/release.sh: the version and the commit come from its git tag. Nil for a build from Xcode
    /// (WP_GIT_COMMIT stays "dev").
    static var release: (version: String, commit: String)? {
        let info = Bundle.main.infoDictionary
        guard let commit = info?["WPGitCommit"] as? String, !commit.isEmpty, commit != "dev",
              let version = info?["CFBundleShortVersionString"] as? String else { return nil }
        return (version, commit)
    }

    /// `Legal/PrivacyPolicy-<en|ru>.md` in the app's language.
    static var privacyPolicy: String {
        resource(CoreLanguage.current == .ru ? "PrivacyPolicy-ru" : "PrivacyPolicy-en", "md")
    }

    /// `Legal/Acknowledgements.txt`, written by `GoMobile/licenses.sh`.
    static var acknowledgements: String {
        resource("Acknowledgements", "txt")
    }

    private static func resource(_ name: String, _ ext: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }
}

/// The privacy policy, rendered from its Markdown (headings and paragraphs).
struct PrivacyPolicyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .title(let text):
                        Text(verbatim: text).font(.title2.bold())
                    case .heading(let text):
                        Text(verbatim: text).font(.headline).padding(.top, 6)
                    case .paragraph(let text):
                        Text(text).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity)
            .textSelection(.enabled)
        }
        .navigationTitle("Privacy Policy")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private enum Block {
        case title(String), heading(String), paragraph(AttributedString)
    }

    private var blocks: [Block] {
        AppInfo.privacyPolicy.components(separatedBy: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return nil }
            if trimmed.hasPrefix("## ") { return .heading(String(trimmed.dropFirst(3))) }
            if trimmed.hasPrefix("# ") { return .title(String(trimmed.dropFirst(2))) }
            return .paragraph((try? AttributedString(markdown: trimmed)) ?? AttributedString(trimmed))
        }
    }
}

/// Licenses of the open-source software inside the app (go2rtc and its Go modules).
struct LicensesView: View {
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(verbatim: paragraph)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(paragraph.hasPrefix("====") ? .primary : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
            .textSelection(.enabled)
        }
        .navigationTitle("Open-Source Licenses")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var paragraphs: [String] {
        AppInfo.acknowledgements.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
