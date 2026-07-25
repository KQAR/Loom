import SwiftUI

struct CookiesView: View {
    let cookies: [CookieItem]
    var body: some View {
        if cookies.isEmpty {
            Text("No cookies").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: LoomTheme.Space.sm) {
                ForEach(cookies) { cookie in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .top, spacing: LoomTheme.Space.xs) {
                            Text(cookie.name)
                                .foregroundStyle(.secondary)
                            Text(cookie.value)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.callout.monospaced())
                        if !cookie.attributes.isEmpty {
                            Text(cookie.attributes)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }
}
