import UIKit

@MainActor
enum AppHaptics {
    // Created once and reused: a fresh, unprepared generator per event allocates on every
    // tap and adds latency while the Taptic Engine spins up.
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let notificationGenerator = UINotificationFeedbackGenerator()
    private static var impactGenerators: [UIImpactFeedbackGenerator.FeedbackStyle: UIImpactFeedbackGenerator] = [:]

    private static func impactGenerator(_ style: UIImpactFeedbackGenerator.FeedbackStyle) -> UIImpactFeedbackGenerator {
        if let generator = impactGenerators[style] {
            return generator
        }
        let generator = UIImpactFeedbackGenerator(style: style)
        impactGenerators[style] = generator
        return generator
    }

    @discardableResult
    static func performIfEnabled(
        defaults: UserDefaults = .standard,
        action: () -> Void
    ) -> Bool {
        guard defaults.enableHapticsPreference else {
            return false
        }

        action()
        return true
    }

    /// Call when an interaction that ends in a selection haptic starts, such as a drag.
    static func prepareSelectionFeedback() {
        performIfEnabled {
            selectionGenerator.prepare()
        }
    }

    static func selectionChanged() {
        performIfEnabled {
            selectionGenerator.selectionChanged()
        }
    }

    static func impact(
        _ style: UIImpactFeedbackGenerator.FeedbackStyle,
        intensity: CGFloat? = nil
    ) {
        performIfEnabled {
            let generator = impactGenerator(style)
            if let intensity {
                generator.impactOccurred(intensity: intensity)
            } else {
                generator.impactOccurred()
            }
        }
    }

    static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        performIfEnabled {
            notificationGenerator.notificationOccurred(type)
        }
    }

    static func generationCompleted() async {
        let generator = impactGenerator(.light)
        let didStart = performIfEnabled {
            generator.prepare()
            generator.impactOccurred(intensity: 0.7)
        }
        guard didStart else { return }
        try? await Task.sleep(for: .milliseconds(80))
        generator.impactOccurred(intensity: 1.0)
    }
}
