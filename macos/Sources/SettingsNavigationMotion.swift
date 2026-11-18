import SwiftUI

/// Keep native toolbar replacement out of the visible part of the layout change.
/// Each request invalidates pending completions, so reversing never queues moves.
final class SettingsNavigationMotion: ObservableObject {
    @Published private(set) var layoutExpanded: Bool
    @Published private(set) var headerExpanded: Bool
    @Published private(set) var headerOpacity = 1.0
    @Published private(set) var sidebarOpacity: Double
    @Published private(set) var isTransitioning = false
    @Published private(set) var headerRevision = 0
    private(set) var revision = 0
    private var pendingHeader: Int?
    private var task: Task<Void, Never>?

    init(expanded: Bool) {
        layoutExpanded = expanded
        headerExpanded = expanded
        sidebarOpacity = expanded ? 1 : 0
    }

    func settle(expanded: Bool) {
        task?.cancel(); task = nil
        revision += 1; pendingHeader = nil
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            layoutExpanded = expanded; headerExpanded = expanded
            sidebarOpacity = expanded ? 1 : 0
            headerOpacity = 1; isTransitioning = false
            headerRevision = revision
        }
    }

    func move(to expanded: Bool, reduceMotion: Bool) {
        guard !reduceMotion else { settle(expanded: expanded); return }
        task?.cancel()
        revision += 1
        let requested = revision
        pendingHeader = nil
        isTransitioning = true
        task = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.revision == requested else { return }
            await self.animate(.easeOut(duration: 0.08)) {
                self.headerOpacity = 0
                if !expanded { self.sidebarOpacity = 0 }
            }
            guard !Task.isCancelled, self.revision == requested else { return }
            await self.animate(.smooth(duration: 0.30, extraBounce: 0)) {
                self.layoutExpanded = expanded
                self.sidebarOpacity = expanded ? 1 : 0
            }
            guard !Task.isCancelled, self.revision == requested else { return }
            self.pendingHeader = requested
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                self.headerExpanded = expanded
                // A reversal can end on the existing header. Request its layout
                // acknowledgement only now, after the width has settled.
                self.headerRevision = requested
            }
        }
    }

    func headerDidLayout(expanded: Bool, revision requested: Int) {
        guard requested == revision, pendingHeader == requested,
              headerExpanded == expanded, layoutExpanded == expanded else { return }
        pendingHeader = nil
        withAnimation(.easeInOut(duration: 0.14), completionCriteria: .removed) {
            headerOpacity = 1
        } completion: { [weak self] in
            guard let self, self.revision == requested else { return }
            self.isTransitioning = false
            self.task = nil
        }
    }

    @MainActor private func animate(_ animation: Animation, _ change: () -> Void) async {
        await withCheckedContinuation { continuation in
            withAnimation(animation, completionCriteria: .removed, change) {
                continuation.resume()
            }
        }
    }
}
