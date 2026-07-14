import SwiftUI

struct MenuBarIcon: View {
    let state: ConnectionState

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 18, size.height / 16)
            let xOffset = (size.width - 18 * scale) / 2
            let yOffset = (size.height - 16 * scale) / 2

            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: xOffset + x * scale, y: yOffset + y * scale)
            }

            func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
                CGRect(
                    x: xOffset + x * scale,
                    y: yOffset + y * scale,
                    width: width * scale,
                    height: height * scale
                )
            }

            let stroke = StrokeStyle(
                lineWidth: 1.65 * scale,
                lineCap: .round,
                lineJoin: .round
            )

            if state == .disconnected {
                var leftCable = Path()
                leftCable.move(to: point(4, 5.1))
                leftCable.addLine(to: point(4, 8.2))
                leftCable.addCurve(
                    to: point(8.05, 13.95),
                    control1: point(4, 11.8),
                    control2: point(6.05, 13.95)
                )

                var rightCable = Path()
                rightCable.move(to: point(9.95, 13.95))
                rightCable.addCurve(
                    to: point(14, 8.2),
                    control1: point(11.95, 13.95),
                    control2: point(14, 11.8)
                )
                rightCable.addLine(to: point(14, 5.1))

                context.stroke(leftCable, with: .foreground, style: stroke)
                context.stroke(rightCable, with: .foreground, style: stroke)
            } else {
                var cable = Path()
                cable.move(to: point(4, 5.1))
                cable.addLine(to: point(4, 8.2))
                cable.addCurve(
                    to: point(9, 14.1),
                    control1: point(4, 12),
                    control2: point(6.2, 14.1)
                )
                cable.addCurve(
                    to: point(14, 8.2),
                    control1: point(11.8, 14.1),
                    control2: point(14, 12)
                )
                cable.addLine(to: point(14, 5.1))

                context.stroke(
                    cable,
                    with: .foreground,
                    style: state == .connecting
                        ? StrokeStyle(
                            lineWidth: stroke.lineWidth,
                            lineCap: .round,
                            lineJoin: .round,
                            dash: [1.5 * scale, 1.5 * scale]
                        )
                        : stroke
                )
            }

            for socketX in [2.1, 12.1] {
                let socket = Path(ellipseIn: rect(socketX, 1.1, 3.8, 3.8))
                context.stroke(socket, with: .foreground, lineWidth: 1.35 * scale)
            }

            if state == .failed {
                drawFailureMark(in: &context, scale: scale, point: point)
            }
        }
        .frame(width: 18, height: 16)
        .foregroundStyle(.primary)
        .accessibilityHidden(true)
    }

    private func drawFailureMark(
        in context: inout GraphicsContext,
        scale: CGFloat,
        point: (CGFloat, CGFloat) -> CGPoint
    ) {
        var cross = Path()
        cross.move(to: point(8.25, 2.25))
        cross.addLine(to: point(9.75, 3.75))
        cross.move(to: point(9.75, 2.25))
        cross.addLine(to: point(8.25, 3.75))
        context.stroke(
            cross,
            with: .foreground,
            style: StrokeStyle(lineWidth: 1 * scale, lineCap: .round)
        )
    }
}

#if DEBUG
struct MenuBarIconPreview: View {
    private let states: [ConnectionState] = [.connected, .connecting, .disconnected, .failed]

    var body: some View {
        VStack(spacing: 0) {
            iconRow
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))

            iconRow
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .environment(\.colorScheme, .dark)
        }
        .frame(width: 240, height: 112)
    }

    private var iconRow: some View {
        HStack(spacing: 24) {
            ForEach(states, id: \.rawValue) { state in
                MenuBarIcon(state: state)
            }
        }
    }
}
#endif
