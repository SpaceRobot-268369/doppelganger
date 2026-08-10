import SwiftUI

/// Compare: check whether several folders or files really do hold the same
/// content, by checksum rather than by size and date.
///
/// The feature is announced here but not yet built. The page says so plainly
/// instead of offering controls that would do nothing — an offload tool must
/// never imply a check it did not run.
struct CompareView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                summaryCard
                capabilityGrid
                Text("Until this arrives, a transfer's own verification and its manifest remain the record of what was copied and proven.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Compare")
                .font(.largeTitle.weight(.bold))
            Text("Coming soon")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .glassEffect(.regular, in: .capsule)
            Spacer()
        }
    }

    private var summaryCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "equal.square")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
                .frame(width: 46, height: 46)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 8) {
                Text("Prove two copies are identical")
                    .font(.title3.weight(.semibold))
                Text("Point Compare at several folders or files, nominate one as the primary, and it checksums every file on both sides. The result says which files match, which differ, which are missing from a copy, and which exist only in it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.separator.opacity(0.45)))
    }

    private var capabilityGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What it will do")
                .font(.headline)
            capability(
                "Pick the primary",
                detail: "One folder or file is the reference every other copy is judged against, so a difference always has a direction.",
                symbol: "star.circle"
            )
            capability(
                "Compare by checksum",
                detail: "Content is hashed and matched, not inferred from size and modification date.",
                symbol: "number.circle"
            )
            capability(
                "Missing and extra files",
                detail: "Anything absent from a copy, and anything present only in it, is listed rather than summarised away.",
                symbol: "list.bullet.rectangle"
            )
            capability(
                "A result you can hand over",
                detail: "The comparison reads like the rest of the app: a plain verdict first, the full detail underneath.",
                symbol: "doc.text.magnifyingglass"
            )
        }
    }

    private func capability(
        _ title: LocalizedStringKey,
        detail: LocalizedStringKey,
        symbol: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    CompareView()
}
