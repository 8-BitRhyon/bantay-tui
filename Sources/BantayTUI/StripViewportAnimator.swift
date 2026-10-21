import Foundation

/// Drives physics-based spring viewport animations at 120Hz/60Hz display refresh.
@MainActor
public final class StripViewportAnimator: ObservableObject {
    @Published public private(set) var currentOffset: Double = 0.0
    @Published public private(set) var isAnimating: Bool = false

    private var spring: DampedSpring
    private var timer: DispatchSourceTimer?
    private var lastTickTime: DispatchTime = .now()

    public var onUpdate: ((Double) -> Void)?
    public var onFinished: (() -> Void)?

    public init(initialOffset: Double = 0.0) {
        self.spring = DampedSpring(initialValue: initialOffset)
        self.currentOffset = initialOffset
    }

    /// Sets a new target scroll position and begins spring animation.
    public func animateTo(target: Double, omega: Double = 13.0) {
        spring.target = target
        guard !isAnimating else { return }

        isAnimating = true
        lastTickTime = .now()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        // 8ms interval (~120 FPS for ProMotion displays, with 1ms leeway)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            self?.tick(omega: omega)
        }
        self.timer = timer
        timer.resume()
    }

    /// Snaps immediately to the given target offset without animation.
    public func snapTo(target: Double) {
        stop()
        spring.target = target
        spring.snap()
        currentOffset = spring.x
        onUpdate?(currentOffset)
    }

    /// Directly adjust offset during interactive 1:1 trackpad dragging.
    public func applyInteractiveOffset(_ offset: Double) {
        stop()
        spring.x = offset
        spring.target = offset
        spring.v = 0.0
        currentOffset = offset
        onUpdate?(currentOffset)
    }

    private func tick(omega: Double) {
        let now = DispatchTime.now()
        let nanoDelta = now.uptimeNanoseconds - lastTickTime.uptimeNanoseconds
        let dt = min(0.05, max(0.001, Double(nanoDelta) / 1_000_000_000.0))
        lastTickTime = now

        let moving = spring.step(dt: dt, omega: omega)
        currentOffset = spring.x
        onUpdate?(currentOffset)

        if !moving {
            stop()
            onFinished?()
        }
    }

    /// Halts active animation.
    public func stop() {
        timer?.cancel()
        timer = nil
        isAnimating = false
    }

    deinit {
        timer?.cancel()
    }
}
