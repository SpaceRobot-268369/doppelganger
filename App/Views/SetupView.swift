import SwiftUI

struct SetupView: View {
    @Bindable var model: TransferViewModel
    @State private var pickingSource = false
    @State private var pickingDestination = false

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.tint)
                Text("Doppelganger")
                    .font(.largeTitle.weight(.semibold))
                Text("Copy. Verify every byte. Prove it.")
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)

            sourceCard
            destinationsCard

            if let message = model.validationMessage {
                Label(message, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button {
                model.start()
            } label: {
                Label("Start Transfer", systemImage: "play.fill")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: 320)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(.blue)
            .disabled(!model.canStart)
            .padding(.bottom, 8)
        }
        .padding(28)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sourceCard: some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: "sdcard")
                    .font(.title2)
                    .foregroundStyle(model.source == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Source")
                        .font(.headline)
                    Text(model.source.map { Format.middleTruncated($0.path) } ?? "No source selected")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose…") { pickingSource = true }
                    .buttonStyle(.glass)
            }
            .padding(6)
        }
        .fileImporter(isPresented: $pickingSource, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.source = url }
        }
    }

    private var destinationsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(model.destinations.enumerated()), id: \.offset) { index, destination in
                    HStack(spacing: 12) {
                        Image(systemName: "externaldrive")
                            .font(.title3)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Destination \(index + 1)")
                                .font(.headline)
                            Text(Format.middleTruncated(destination.path))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            model.removeDestination(at: index)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove this destination")
                    }
                }
                if model.destinations.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "externaldrive.badge.questionmark")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text("Every destination gets a verified copy and a manifest.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    pickingDestination = true
                } label: {
                    Label("Add Destination…", systemImage: "plus")
                }
                .buttonStyle(.glass)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fileImporter(isPresented: $pickingDestination, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.addDestination(url) }
        }
    }
}
