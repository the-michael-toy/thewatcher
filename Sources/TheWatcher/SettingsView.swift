import SwiftUI
import WatcherCore

struct SettingsView: View {
    let monitor: Monitor
    @AppStorage(Settings.notifyOnRecoveryKey) private var notifyOnRecovery = true
    @State private var openAtLogin = LoginItem.isEnabled
    @State private var editing: [Int64: String] = [:]
    @State private var newPlaceName = ""

    var body: some View {
        Form {
            Section {
                Toggle("Notify me when the internet comes back after an outage", isOn: $notifyOnRecovery)
                    .onChange(of: notifyOnRecovery) { _, on in if on { Notifier.requestPermission() } }
                Toggle("Open TheWatcher at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in LoginItem.set(on) }
            }
            Section("Places that keep history") {
                if monitor.places.isEmpty && !canAddCurrent {
                    Text("None yet. Connect to a network you want to track, then add it here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(monitor.places) { place in
                    HStack {
                        TextField("Name", text: Binding(
                            get: { editing[place.id] ?? place.name },
                            set: { editing[place.id] = $0 }))
                            .onSubmit { commit(place) }
                        if monitor.place?.id == place.id {
                            Text("here now").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Re-learn normal") { monitor.relearn(place) }
                            .help("Forget what latency is normal here; the next few minutes set it again")
                        Button("Forget", role: .destructive) { monitor.forget(place) }
                            .help("Stop keeping history here and delete what was recorded")
                    }
                }
                if canAddCurrent {
                    HStack {
                        TextField("Name for this network", text: $newPlaceName)
                            .onSubmit(keepCurrent)
                        Button("Keep history here", action: keepCurrent)
                            .disabled(newPlaceName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, minHeight: 360)
    }

    /// The network the Mac is on now can be identified but isn't kept yet.
    private var canAddCurrent: Bool {
        monitor.store != nil && monitor.place == nil && monitor.path?.fingerprint != nil
    }

    private func keepCurrent() {
        let name = newPlaceName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        monitor.keepHistoryHere(name: name)
        newPlaceName = ""
    }

    private func commit(_ place: Place) {
        guard let name = editing[place.id]?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
        monitor.rename(place, to: name)
        editing[place.id] = nil
    }
}
