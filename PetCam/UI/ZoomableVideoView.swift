import SwiftUI
import UIKit

/// The live picture. Pinch or double-tap to zoom; when not zoomed, a one-finger drag
/// steers the camera ("drag the scene": swipe left to look further right).
struct ZoomableVideoView: UIViewRepresentable {
    let videoView: VideoLayerView
    var onSteer: (PTZDirection?) -> Void
    var onTap: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> VideoScrollView {
        let scroll = VideoScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.bouncesZoom = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .black
        scroll.panGestureRecognizer.isEnabled = false

        videoView.removeFromSuperview()
        videoView.transform = .identity
        scroll.addSubview(videoView)
        scroll.contentView = videoView

        let coordinator = context.coordinator
        coordinator.scrollView = scroll

        let steer = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleSteer(_:)))
        steer.maximumNumberOfTouches = 1
        scroll.addGestureRecognizer(steer)
        coordinator.steerGesture = steer

        let doubleTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)

        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.require(toFail: doubleTap)
        scroll.addGestureRecognizer(tap)

        return scroll
    }

    func updateUIView(_ scroll: VideoScrollView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleUIView(_ scroll: VideoScrollView, coordinator: Coordinator) {
        coordinator.endSteering()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableVideoView
        weak var scrollView: VideoScrollView?
        weak var steerGesture: UIPanGestureRecognizer?
        private var currentDirection: PTZDirection?

        init(parent: ZoomableVideoView) { self.parent = parent }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? VideoScrollView)?.contentView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let zoomed = scrollView.zoomScale > 1.01
            scrollView.panGestureRecognizer.isEnabled = zoomed
            steerGesture?.isEnabled = !zoomed
        }

        @objc func handleSteer(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .began, .changed:
                let t = gesture.translation(in: gesture.view)
                let direction = PTZDirection.from(dx: -t.x, dy: -t.y, deadZone: 24)
                if direction != currentDirection {
                    currentDirection = direction
                    parent.onSteer(direction)
                    if direction != nil { UISelectionFeedbackGenerator().selectionChanged() }
                }
            default:
                endSteering()
            }
        }

        func endSteering() {
            guard currentDirection != nil else { return }
            currentDirection = nil
            parent.onSteer(nil)
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            parent.onTap()
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll = scrollView, let content = scroll.contentView else { return }
            if scroll.zoomScale > 1.01 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = gesture.location(in: content)
                let scale: CGFloat = 2.5
                let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
                let rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
                scroll.zoom(to: rect, animated: true)
            }
        }
    }
}

final class VideoScrollView: UIScrollView {
    weak var contentView: UIView?
    private var lastSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let contentView, bounds.size != lastSize, bounds.width > 0 else { return }
        lastSize = bounds.size
        setZoomScale(1, animated: false)
        contentView.frame = CGRect(origin: .zero, size: bounds.size)
        contentSize = bounds.size
    }
}
