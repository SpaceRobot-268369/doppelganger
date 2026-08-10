import SwiftUI

private enum OnboardingStep: String, CaseIterable, Identifiable {
    case welcome = "Welcome"
    case permissions = "Permissions"
    case profile = "Profile"
    case demo = "Demo"

    var id: String { rawValue }
}

struct OnboardingView: View {
    @Bindable var model: AppModel
    let finish: (_ prepareDemo: Bool) -> Void

    @State private var step = OnboardingStep.welcome
    @State private var profileName = ""
    @State private var demoError: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Welcome to Doppelganger")
                    .font(.largeTitle.weight(.bold))
                Text("A local, open-source media offload workflow for macOS.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 26)

            HStack(spacing: 9) {
                ForEach(OnboardingStep.allCases) { item in
                    SubtabFilterChip(item.rawValue, isSelected: step == item) {
                        saveProfileIfNeeded()
                        step = item
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)

            Group {
                switch step {
                case .welcome: welcome
                case .permissions: permissions
                case .profile: profile
                case .demo: demo
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(28)

            Divider()
            HStack {
                Button("Finish Later") { finish(false) }
                    .buttonStyle(.glass)
                Spacer()
                if let previousStep {
                    Button("Back") { step = previousStep }
                        .buttonStyle(.glass)
                }
                if let nextStep {
                    Button("Continue") {
                        saveProfileIfNeeded()
                        step = nextStep
                    }
                    .buttonStyle(.glassProminent)
                } else {
                    Button("Start Using Doppelganger") {
                        saveProfileIfNeeded()
                        finish(false)
                    }
                    .buttonStyle(.glassProminent)
                }
            }
            .padding(18)
        }
        .frame(width: 720, height: 570)
        .onAppear {
            profileName = model.productStore.activeProfile.displayName
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            onboardingCard(
                symbol: "arrow.triangle.branch",
                title: "One source, independent destinations",
                text: "Every destination connects directly to the source. A destination is never silently used as the next source."
            )
            onboardingCard(
                symbol: "checkmark.shield",
                title: "Copy is not verification",
                text: "Green means every destination copy was independently read and matched. Fast transfers remain yellow until verification completes."
            )
            onboardingCard(
                symbol: "doc.badge.gearshape",
                title: "Portable evidence",
                text: "JSON, Markdown, and MHL artifacts travel with the media; the local catalog makes tasks searchable."
            )
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("File access on macOS")
                .font(.title2.weight(.bold))
            Text("Doppelganger asks you to choose sources and destinations when they are needed. It cannot see folders that macOS has not allowed the app to access.")
                .foregroundStyle(.secondary)
            onboardingCard(
                symbol: "externaldrive.badge.checkmark",
                title: "External and removable volumes",
                text: "If a card or drive does not appear, reconnect it, verify it is mounted in Finder, and choose it again from the app."
            )
            onboardingCard(
                symbol: "lock.shield",
                title: "Privacy & Security",
                text: "For protected folders, review System Settings › Privacy & Security › Files & Folders. Doppelganger never claims access before macOS grants it."
            )
            Text("Automatic Camera/Card recognition is off by default. You can enable review suggestions later in Settings › Transfer; no task ever auto-starts.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var profile: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Who is operating this Mac?")
                .font(.title2.weight(.bold))
            Text("This is local attribution, not a login. Each task snapshots the selected profile so history still shows who operated it after a profile is renamed.")
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                OperatorAvatarView(
                    profile: model.productStore.activeProfile,
                    avatarStore: model.productStore.avatars,
                    size: 72
                )
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Operator name", text: $profileName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 340)
                    Text("Add more profiles and image avatars later in Settings › Profiles.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            onboardingCard(
                symbol: "person.crop.circle.badge.checkmark",
                title: "Visible throughout the app",
                text: "The active avatar appears in the sidebar, new-task review, transfer cards, audit events, and history."
            )
        }
    }

    private var demo: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Try a safe demo transfer")
                .font(.title2.weight(.bold))
            Text("Doppelganger can create a tiny synthetic card and two empty destinations inside its own Application Support folder, then open the normal preflight review.")
                .foregroundStyle(.secondary)
            onboardingCard(
                symbol: "testtube.2",
                title: "Synthetic only",
                text: "The demo contains generated .bin and text files. It does not inspect, modify, eject, or delete any real source volume."
            )
            Button {
                saveProfileIfNeeded()
                finish(true)
            } label: {
                Label("Create Demo and Review Transfer", systemImage: "play.rectangle.fill")
            }
            .buttonStyle(.glassProminent)
            if let demoError {
                Label(demoError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private var previousStep: OnboardingStep? {
        guard let index = OnboardingStep.allCases.firstIndex(of: step), index > 0 else { return nil }
        return OnboardingStep.allCases[index - 1]
    }

    private var nextStep: OnboardingStep? {
        guard let index = OnboardingStep.allCases.firstIndex(of: step),
              index < OnboardingStep.allCases.count - 1 else { return nil }
        return OnboardingStep.allCases[index + 1]
    }

    private func saveProfileIfNeeded() {
        let value = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != model.productStore.activeProfile.displayName else { return }
        model.productStore.updateProfile(model.productStore.activeProfile, displayName: value)
    }

    private func onboardingCard(symbol: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title)).font(.headline)
                Text(LocalizedStringKey(text)).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.4)))
    }
}
