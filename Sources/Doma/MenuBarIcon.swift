import AppKit
import SwiftUI

enum MenuBarIcon {
    private static let size = NSSize(width: 18, height: 16)

    static func image(for state: ConnectionState) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            let scale = min(rect.width / size.width, rect.height / size.height)
            let xOffset = rect.minX + (rect.width - size.width * scale) / 2
            let yOffset = rect.minY + (rect.height - size.height * scale) / 2

            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                NSPoint(
                    x: xOffset + x * scale,
                    y: yOffset + (size.height - y) * scale
                )
            }

            func ovalRect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
                NSRect(
                    x: xOffset + x * scale,
                    y: yOffset + (size.height - y - height) * scale,
                    width: width * scale,
                    height: height * scale
                )
            }

            NSColor.black.setStroke()
            drawCable(state: state, scale: scale, point: point)

            for socketX in [2.1, 12.1] {
                let socket = NSBezierPath(ovalIn: ovalRect(socketX, 1.1, 3.8, 3.8))
                style(socket, lineWidth: 1.35 * scale)
                socket.stroke()
            }

            if state == .failed {
                drawFailureMark(scale: scale, point: point)
            }

            return true
        }

        image.isTemplate = true
        image.accessibilityDescription = "Doma: \(state.title)"
        return image
    }

    private static func drawCable(
        state: ConnectionState,
        scale: CGFloat,
        point: (CGFloat, CGFloat) -> NSPoint
    ) {
        if state == .disconnected {
            let leftCable = NSBezierPath()
            leftCable.move(to: point(4, 5.1))
            leftCable.line(to: point(4, 8.2))
            leftCable.curve(
                to: point(8.05, 13.95),
                controlPoint1: point(4, 11.8),
                controlPoint2: point(6.05, 13.95)
            )
            style(leftCable, lineWidth: 1.65 * scale)
            leftCable.stroke()

            let rightCable = NSBezierPath()
            rightCable.move(to: point(9.95, 13.95))
            rightCable.curve(
                to: point(14, 8.2),
                controlPoint1: point(11.95, 13.95),
                controlPoint2: point(14, 11.8)
            )
            rightCable.line(to: point(14, 5.1))
            style(rightCable, lineWidth: 1.65 * scale)
            rightCable.stroke()
            return
        }

        let cable = NSBezierPath()
        cable.move(to: point(4, 5.1))
        cable.line(to: point(4, 8.2))
        cable.curve(
            to: point(9, 14.1),
            controlPoint1: point(4, 12),
            controlPoint2: point(6.2, 14.1)
        )
        cable.curve(
            to: point(14, 8.2),
            controlPoint1: point(11.8, 14.1),
            controlPoint2: point(14, 12)
        )
        cable.line(to: point(14, 5.1))
        style(cable, lineWidth: 1.65 * scale)

        if state == .connecting {
            let dashes = [1.5 * scale, 1.5 * scale]
            dashes.withUnsafeBufferPointer { buffer in
                cable.setLineDash(buffer.baseAddress, count: buffer.count, phase: 0)
            }
        }

        cable.stroke()
    }

    private static func drawFailureMark(
        scale: CGFloat,
        point: (CGFloat, CGFloat) -> NSPoint
    ) {
        let cross = NSBezierPath()
        cross.move(to: point(8.25, 2.25))
        cross.line(to: point(9.75, 3.75))
        cross.move(to: point(9.75, 2.25))
        cross.line(to: point(8.25, 3.75))
        style(cross, lineWidth: scale)
        cross.stroke()
    }

    private static func style(_ path: NSBezierPath, lineWidth: CGFloat) {
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
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
                Image(nsImage: MenuBarIcon.image(for: state))
                    .renderingMode(.template)
            }
        }
    }
}
#endif
