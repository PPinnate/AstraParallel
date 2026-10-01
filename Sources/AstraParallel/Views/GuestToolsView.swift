import SwiftUI

struct GuestToolsView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Install Astra Guest Tools").font(.title2.bold())
            Text("The installer disc is included with Astra and is attached when Windows starts.")
            Text("1. In Windows, open File Explorer → This PC → Astra Guest Tools.\n2. Double-click Install Astra Tools.cmd and approve the Windows administrator prompt.\n3. Restart Windows when installation finishes.")
                .fixedSize(horizontal: false, vertical: true)
            Text("During Windows setup, if a network driver is requested, browse the Astra Guest Tools disc → Drivers → Network.")
                .foregroundStyle(.secondary)
            Text("The installer includes display, networking, guest integration, and Astra's validated graphics correction. Close games and launchers before installing.")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 500)
    }
}
