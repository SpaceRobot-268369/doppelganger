import SwiftUI

/// Draws the reviewed plan's topology. A transfer's live connectors are
/// `ConnectorView`; this one carries no execution state, only how the plan
/// reads before it runs.
///
/// With one source, every destination gets its own line straight from it. With
/// several sources the lines meet at a single junction first, so the drawing
/// grows with sources + destinations instead of sources × destinations. The
/// junction is a bundling point, never a hop: no copy is ever drawn or made as
/// source → destination 1 → destination 2.
struct PlanConnectorView: View {
    enum PlanState {
        /// Nothing has been scanned yet, so the plan is only a proposal.
        case unreviewed
        case blocked
        case warning
        case ready
    }

    let sourceCenters: [CGFloat]
    let destinationCenters: [CGFloat]
    let state: PlanState
    /// How many independent tasks the junction stands for. Rows and tasks are
    /// not the same thing: several files picked out of one folder draw a row
    /// each but still run as the single task that folder becomes.
    var taskCount: Int?
    /// Index of the source the pointer is over, if any. Its leg into the
    /// junction stays solid while the others fade back.
    var highlightedSource: Int?

    var body: some View {
        Canvas { context, size in
            guard !sourceCenters.isEmpty, !destinationCenters.isEmpty else { return }
            if sourceCenters.count == 1 {
                drawDirectFanOut(context, size: size, sourceY: sourceCenters[0])
            } else {
                drawBundled(context, size: size)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Drawing

    private func drawDirectFanOut(_ context: GraphicsContext, size: CGSize, sourceY: CGFloat) {
        let start = CGPoint(x: 0, y: sourceY)
        for destinationY in destinationCenters {
            let end = CGPoint(x: size.width, y: destinationY)
            stroke(context, from: start, to: end, size: size, dimmed: false)
            fillNode(context, at: midpoint(start: start, end: end, size: size), dimmed: false)
        }
    }

    private func drawBundled(_ context: GraphicsContext, size: CGSize) {
        let junction = CGPoint(x: size.width / 2, y: junctionY)
        for (index, sourceY) in sourceCenters.enumerated() {
            let dimmed = highlightedSource != nil && highlightedSource != index
            stroke(
                context,
                from: CGPoint(x: 0, y: sourceY),
                to: junction,
                size: CGSize(width: size.width / 2, height: size.height),
                dimmed: dimmed
            )
        }
        for destinationY in destinationCenters {
            stroke(
                context,
                from: junction,
                to: CGPoint(x: size.width, y: destinationY),
                size: CGSize(width: size.width / 2, height: size.height),
                dimmed: false
            )
        }
        // The junction reads as a bundle of independent tasks, not a relay.
        let radius: CGFloat = 7
        let ring = Path(ellipseIn: CGRect(
            x: junction.x - radius, y: junction.y - radius,
            width: radius * 2, height: radius * 2
        ))
        context.fill(ring, with: .color(lineColor.opacity(0.22)))
        context.stroke(ring, with: .color(lineColor), style: StrokeStyle(lineWidth: 1.5))
        let count = Text("\(taskCount ?? sourceCenters.count)")
            .font(.system(size: 8, weight: .bold))
            .foregroundColor(.white)
        context.draw(count, at: junction)
    }

    private var junctionY: CGFloat {
        let all = sourceCenters + destinationCenters
        guard !all.isEmpty else { return 0 }
        return all.reduce(0, +) / CGFloat(all.count)
    }

    private func stroke(
        _ context: GraphicsContext,
        from start: CGPoint,
        to end: CGPoint,
        size: CGSize,
        dimmed: Bool
    ) {
        var path = Path()
        path.move(to: start)
        let span = end.x - start.x
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x + span * 0.55, y: start.y),
            control2: CGPoint(x: start.x + span * 0.45, y: end.y)
        )
        context.stroke(
            path,
            with: .color(lineColor.opacity(dimmed ? 0.25 : 1)),
            style: StrokeStyle(lineWidth: dimmed ? 1 : 1.5)
        )
    }

    /// Neutral until the plan has actually been checked; the product never
    /// colours an unverified state as though it passed.
    private var lineColor: Color {
        switch state {
        case .unreviewed: .secondary.opacity(0.45)
        case .blocked: .red.opacity(0.7)
        case .warning: .orange.opacity(0.7)
        case .ready: .blue.opacity(0.65)
        }
    }

    /// Cubic Bézier point at t = 0.5 for the control points used above.
    private func midpoint(start: CGPoint, end: CGPoint, size: CGSize) -> CGPoint {
        let span = end.x - start.x
        let c1 = CGPoint(x: start.x + span * 0.55, y: start.y)
        let c2 = CGPoint(x: start.x + span * 0.45, y: end.y)
        return CGPoint(
            x: (start.x + 3 * c1.x + 3 * c2.x + end.x) / 8,
            y: (start.y + 3 * c1.y + 3 * c2.y + end.y) / 8
        )
    }

    private func fillNode(_ context: GraphicsContext, at point: CGPoint, dimmed: Bool) {
        let radius: CGFloat = state == .unreviewed ? 2.5 : 4
        let circle = Path(ellipseIn: CGRect(
            x: point.x - radius, y: point.y - radius,
            width: radius * 2, height: radius * 2
        ))
        context.fill(circle, with: .color(lineColor.opacity(dimmed ? 0.25 : 1)))
    }
}
