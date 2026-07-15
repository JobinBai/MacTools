import AppKit
import Combine
import OSLog

// MARK: - Floating icon presentation (injectable — tests swap in a spy, design §10-①)

/// The cursor-following floating icon a carry rides in. It lives in its OWN borderless window,
/// NOT in the SwiftUI `NSHostingView` (which froze when mutated mid-drag).
@MainActor
protocol LaunchpadFloatingIconPresenting: AnyObject {
    var isPresenting: Bool { get }
    func present(icon: NSImage?, side: CGFloat, atScreenPoint p: NSPoint, aboveLevel: NSWindow.Level)
    func move(toScreenPoint p: NSPoint)
    /// Fly to the resolved slot, then call `completion` (design §7.2). The caller guards the
    /// completion with a generation token, so a late/lost completion can never tear down a newer
    /// session — and a watchdog timeout reveals the landed cell even if it never arrives.
    func settle(to screenRect: NSRect, completion: @escaping @MainActor () -> Void)
    func dismiss()
}

/// Production presenter: a borderless, mouse-transparent NSWindow one level above the overlay.
@MainActor
final class LaunchpadFloatingIconWindowPresenter: LaunchpadFloatingIconPresenting {
    private var window: NSWindow?
    private var side: CGFloat = 0

    var isPresenting: Bool { window != nil }

    func present(icon: NSImage?, side: CGFloat, atScreenPoint p: NSPoint, aboveLevel: NSWindow.Level) {
        dismiss()
        self.side = side
        let frame = NSRect(x: 0, y: 0, width: side, height: side)
        let win = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.ignoresMouseEvents = true
        win.level = NSWindow.Level(rawValue: aboveLevel.rawValue + 1)
        let iconView = NSImageView(frame: frame)
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        win.contentView = iconView
        window = win
        move(toScreenPoint: p)
        win.orderFront(nil)
    }

    func move(toScreenPoint p: NSPoint) {
        window?.setFrameOrigin(NSPoint(x: p.x - side / 2, y: p.y - side / 2))
    }

    func settle(to screenRect: NSRect, completion: @escaping @MainActor () -> Void) {
        guard let window else { completion(); return }
        // Real flight (design §4/§7.2): a borderless NSWindow animates its FRAME through
        // NSAnimationContext + the window animator proxy — same gentle-overshoot curve the grid's
        // own settle uses, so the icon and the make-way share one feel. `dismiss()` mid-flight
        // (force-complete) just orders the window out; the late completion is then a no-op at the
        // caller (generation token).
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.18, 0.5, 1)
            window.animator().setFrame(screenRect, display: true)
        }, completionHandler: {
            MainActor.assumeIsolated(completion)
        })
    }

    func dismiss() {
        window?.orderOut(nil)
        window = nil
    }
}

// MARK: - Commit routing (pure data, design §1.3)

/// An edge-dwell page flip, as data (design §4.4). The token makes consecutive flips to the same
/// page distinct `onChange` values.
struct LaunchpadFlipRequest: Equatable {
    let token: Int
    let targetPage: Int
}

/// A release, as data: what was carried, where it came from, what the container resolved.
struct LaunchpadCarryCommit {
    let itemID: String
    let origin: LaunchpadCarrySession.Origin
    let result: LaunchpadExternalDropResult
}

/// The store mutation a commit maps to. Applied by the injected `storeApplier` — the data path
/// never travels through a SwiftUI `@Published` token, so a torn-down view can't lose it.
enum CarryStoreAction: Equatable {
    case move(id: String, target: LaunchpadDropTarget?)   // nil target = global tail
    case makeFolder(targetAppID: String, draggedID: String)
    case addToFolder(folderID: String, appID: String)
    case moveOutOfFolder(folderID: String, appID: String, result: LaunchpadExternalDropResult)
    case none                                              // no-op: skip the write; visuals settle as usual
}

/// Coordinates carry sessions (an item dragged OUTSIDE any container — ejected from a folder
/// today, lifted from the root page in step 7) across the separate per-page AppKit grids.
///
/// Flow: while dragging an app inside the open folder, the moment it leaves the folder the folder
/// ZOOMS CLOSED (mid-drag) and a floating icon — hosted in its OWN borderless window — follows the
/// cursor over the launcher. On release the data lands SYNCHRONOUSLY in mouseUp through the
/// injected `storeApplier`; the `@Published commitToken` is a pure VISUAL channel (close the
/// folder, re-select, drop the frozen snapshot) that is harmless to lose if the overlay tears
/// down before SwiftUI consumes it (design §1.3 — the fix for the resign-active commit race).
///
/// It is an `ObservableObject` because the mid-drag folder close must still be requested from an
/// AppKit mouse handler, where mutating the host view's `@State` directly does NOT invalidate the
/// view; `@Published` routes it through SwiftUI `.onChange` in a tracked transaction.
@MainActor
final class LaunchpadDragCoordinator: ObservableObject {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "LaunchpadCarry"
    )

    enum CarryCancelReason {
        case overlayClosed, anchorUnmounted, searchActivated, geometryChanged, shutdown
    }

    enum CarryEndReason { case committed, cancelled }

    /// What the visual channel needs after a commit. The store mutation already happened.
    struct VisualCommit {
        let itemID: String
        let origin: LaunchpadCarrySession.Origin
        let result: LaunchpadExternalDropResult
        /// Where the selection should follow (the moved app / the new or destination folder);
        /// nil when nothing was written.
        let landingID: String?
        /// The id of a folder this commit CREATED (root merge / eject-into-new-folder), or nil.
        /// Both makeFolder store paths return the fresh folder's UUID as the landing id; an
        /// addToFolder landing id is an EXISTING folder and a reorder's is the item itself —
        /// neither should trigger the post-creation auto-open (design §2.6).
        var createdFolderID: String? {
            if case .makeFolder = result { return landingID }
            return nil
        }
    }

    /// True from lift until release/cancel, for ANY carry origin.
    @Published private(set) var carryActive = false
    /// True only while a FOLDER-origin carry is live — drives the mid-drag folder close and the
    /// source folder's thumbnail filter in the host view.
    @Published private(set) var folderEjectActive = false
    /// Bumped on release — VISUAL channel only (close folder / relocate selection / clear the
    /// frozen snapshot). The data was already applied synchronously via `storeApplier`.
    @Published private(set) var commitToken = 0
    private(set) var pendingVisualCommit: VisualCommit?
    /// Bumped when a commit that CREATED a folder finishes its settle reveal (design §2.6,
    /// R1=B): never mid-flight, where mounting the folder panel would fight the
    /// `settlingItemID` park visuals. The grid view consumes it to auto-open the new folder
    /// with its name focused; `revealedFolderID` carries the id. Purely visual and safe to
    /// lose (the folder data already landed at mouseUp).
    @Published private(set) var folderRevealToken = 0
    private(set) var revealedFolderID: String?
    /// Created-folder id staged at a FLIGHT commit, published by the reveal (`finishSettle`).
    private var pendingRevealFolderID: String?

    /// Mirror of the grid view's folder-panel visibility, written by the view at its open/close
    /// seams (`openFolderPanel` / `closeFolder` / the commit unmount / the derived safety net).
    /// The overlay controller's Esc key monitor reads it to implement the §2.4 ladder's MIDDLE
    /// rung — close the open folder before the launcher — without reaching into SwiftUI state.
    @Published private(set) var isFolderOpen = false
    /// Esc-ladder middle rung (design §2.4): bumped by the controller's key monitor when Esc
    /// should close the open folder instead of the launcher. Consumed by the grid view's
    /// `.onChange` — only the view owns the close choreography (commit a live rename, zoom out).
    /// Purely visual and safe to lose on teardown (a torn-down overlay closes everything anyway).
    @Published private(set) var folderCloseRequestToken = 0

    /// View → coordinator folder-visibility sync. Deduped so the semantic seams plus the
    /// derived safety-net `.onChange` don't republish redundantly.
    func folderPanelDidChange(open: Bool) {
        guard isFolderOpen != open else { return }
        isFolderOpen = open
    }

    /// Controller → view: ask the grid to run `closeFolder()` (the Esc ladder's middle rung).
    func requestFolderClose() {
        folderCloseRequestToken += 1
    }

    /// Edge-dwell page-flip request (design §4.4). Published from the dwell state machine — never
    /// from inside a mouse handler's withAnimation — and consumed by the grid's `.onChange`, which
    /// calls `goToPage` in a tracked transaction. Withdrawn (nil) on release/cancel so a flip
    /// can't land after the carry is gone (AR-5).
    @Published private(set) var flipRequest: LaunchpadFlipRequest?
    private var flipToken = 0

    private(set) var carrySession: LaunchpadCarrySession?
    private(set) var endReason: CarryEndReason?

    /// While a settle flight is airborne: the landed item's layoutID. Containers read it in their
    /// layout-skip predicate and in `apply` (park the freshly rebuilt cell off-screen), so the
    /// grid cell can never appear UNDER the still-flying floating icon (double image, §7.3).
    private(set) var settlingItemID: String?
    /// Monotonic settle generation: flight completion / watchdog / force-complete all carry the
    /// generation they were armed with, and a mismatch is a stale callback to ignore (AR-6 — a
    /// late animation completion must never un-park a NEWER session's cell or drop its icon).
    private var settleGeneration = 0
    private var settleTimeoutWork: DispatchWorkItem?

    /// Watchdog for a lost flight completion (animation interrupted, window closed mid-flight):
    /// after this interval the reveal fires unconditionally — the landed icon must never stay
    /// parked off-screen forever (design §7.3-4).
    var settleTimeoutInterval: TimeInterval = 0.5
    /// Test seam: production schedules on the main queue; tests capture the work and fire it
    /// deterministically (no sleeping, design §10).
    var settleTimeoutScheduler: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> DispatchWorkItem =
        { delay, work in
            let item = DispatchWorkItem { MainActor.assumeIsolated(work) }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return item
        }

    /// Test seam for the reveal→dismiss handover: production defers the floating-icon teardown
    /// one runloop turn. The reveal's freshly (re)built cell paints with THIS turn's CA commit,
    /// while `orderOut` hits the window server immediately — a synchronous dismiss therefore
    /// blanks the slot for a frame before the cell's first paint (the merge-folder flicker).
    /// The icon sits exactly on the slot, so the extra frame is invisible. Tests run it inline.
    var settleDismissScheduler: @MainActor (@escaping @MainActor () -> Void) -> Void = { work in
        DispatchQueue.main.async { MainActor.assumeIsolated(work) }
    }

    /// Synchronous mouseUp data path, injected by the overlay controller (it owns both the
    /// coordinator and the layout store). Returns the landing id for the visual channel.
    var storeApplier: (@MainActor (CarryStoreAction, [LaunchpadDisplayCell]) -> String?)?
    /// Test seam: swap the floating-icon window for a spy (design §10-①).
    var floatingPresenterFactory: @MainActor () -> LaunchpadFloatingIconPresenting =
        { LaunchpadFloatingIconWindowPresenter() }

    /// Injectable clock shared by the dwell state machine (design §10-②).
    var now: @MainActor () -> TimeInterval = { CACurrentMediaTime() }

    /// Test seam for the stationary-cursor tick: production schedules a 30Hz timer on BOTH the
    /// `.eventTracking` (live drag loop) and `.common` run-loop modes (constraint 3 — a default-
    /// mode timer starves during direct drags); tests return nil and pump `tickDwell()` manually.
    var dwellTimerFactory: @MainActor (@escaping @MainActor () -> Void) -> Timer? = { tick in
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { _ in
            MainActor.assumeIsolated(tick)
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    var isDwellTimerRunning: Bool { carrySession?.dwellTimer != nil }

    /// Visible-order snapshot + editability staged by the host view when a drag begins
    /// (`onDragBegan` fires before any carry can start); adopted by the next session at lift.
    private var pendingFrozenOrder: [LaunchpadDisplayCell] = []
    private var pendingEditable = true
    /// Set when a live carry is cancelled, cleared at the next gesture boundary
    /// (`gestureBegan`; `freezeVisibleOrder` keeps clearing it as belt-and-braces). A cancelled
    /// gesture's orphan events must STAY orphaned (design §1.2): without this latch the grid's
    /// late-eject fallback (`commitOut` with no session) could re-open a session from the same
    /// mouse gesture — with stale staged editability — and commit the very drop the cancel
    /// aborted. It must die WITH that gesture though: the root-lift gate reads it before
    /// `onDragBegan` can run, so a latch that only `freezeVisibleOrder` clears would be
    /// permanently unresettable after one mid-carry cancel and wedge every later root drag.
    private var carryCancelledThisGesture = false

    private struct WeakContainer { weak var value: LaunchpadGridContainerView? }

    /// Every root page container, keyed by page index. The SwiftUI paging `.offset` never enters
    /// the AppKit frame chain, so cross-page work cannot lean on `convert` against these views —
    /// the registry plus the pushed `geometry` snapshot replace it (design §3/§5).
    private var pages: [Int: WeakContainer] = [:]
    /// Mirrors the SwiftUI `currentPage` @State via the single `.onChange` funnel.
    private(set) var currentPage = 0
    /// Viewport/page geometry pushed from the grid (AppKit window space, Equatable-deduped).
    private(set) var geometry = LaunchpadPageGeometry()

    /// The container an external drag should classify against — the visible page's grid.
    private var activeContainer: LaunchpadGridContainerView? { pages[currentPage]?.value }

    /// The container a live carry is ENGAGED with (begin/end pairing). Distinct from
    /// `activeContainer`: the engaged one keeps its make-way gap until a handoff explicitly ends
    /// it, so a mid-carry page flip can never leave a stale gap behind (design §3, gap1).
    private(set) weak var currentTargetContainer: LaunchpadGridContainerView?
    private(set) var currentTargetPage = 0

    /// Window-point → page-local arithmetic from the pushed geometry; nil until the first push.
    private var carrySpace: LaunchpadCarrySpace? {
        guard geometry.pageWidth > 0 else { return nil }
        return LaunchpadCarrySpace(viewportMinX: geometry.viewportMinX,
                                   viewportTopY: geometry.viewportTopY,
                                   pageWidth: geometry.pageWidth)
    }

    /// Every page container registers itself (not just the visible one) so the page flipped to
    /// during a carry is already reachable. Pure dictionary write — safe before any cells exist,
    /// and deliberately called ABOVE the container's deferred-apply guard (design §3.1).
    func registerPageContainer(_ container: LaunchpadGridContainerView, page: Int) {
        pages[page] = WeakContainer(value: container)
        reattachIfNeeded(container, page: page)
    }

    /// Containers unregister when leaving the window (page-count shrink, overlay teardown).
    func unregisterPageContainer(_ container: LaunchpadGridContainerView) {
        for (page, boxed) in pages where boxed.value === container || boxed.value == nil {
            pages.removeValue(forKey: page)
        }
        if container === currentTargetContainer { currentTargetContainer = nil }
    }

    /// Single funnel for page changes (every flip path goes through the `currentPage` @State).
    /// During a carry this is the HANDOFF point: the old page's gap animates closed, the new
    /// page's container takes over and is immediately fed the last cursor point so its make-way
    /// opens without waiting for the next mouse event (design §3.2).
    func currentPageDidChange(_ page: Int) {
        currentPage = page
        scheduleGeometryProbe()
        guard let session = carrySession, session.isCarrying, page != currentTargetPage else { return }
        engage(pages[page]?.value, page: page, session: session)
    }

    /// Fallback handoff keyed on container IDENTITY, not page number — covers a target page whose
    /// container mounts late (virtual tail page) or is swapped for a new instance after a
    /// page-count clamp (design §3.3). Shares the begin/end primitive with the funnel; both ends
    /// are idempotent.
    private func reattachIfNeeded(_ container: LaunchpadGridContainerView, page: Int) {
        guard let session = carrySession, session.isCarrying,
              page == currentTargetPage, container !== currentTargetContainer else { return }
        engage(container, page: page, session: session)
    }

    /// The single begin/end pairing point: at any moment at most ONE container is external-drag
    /// active. Ends the old engagement (gap closes), engages the new container, and replays the
    /// last cursor point so the new page starts making way immediately.
    private func engage(_ container: LaunchpadGridContainerView?, page: Int,
                        session: LaunchpadCarrySession) {
        currentTargetContainer?.endExternalDrag()
        currentTargetPage = page
        currentTargetContainer = container
        // A carried FOLDER must never arm a merge — no nested folders (design §1.5).
        container?.beginExternalDrag(appID: session.itemID, allowsMerge: session.isApp)
        session.resumeTracking()
        feedLastPoint(session)
    }

    /// A late-mounting target container registers BEFORE its first cells exist (registration sits
    /// above the apply body), so the reattach replay lands on an empty grid and is dropped. The
    /// container calls this after (re)building cells so the engaged page still opens its make-way
    /// without waiting for the next mouse event.
    func containerDidApplyCells(_ container: LaunchpadGridContainerView) {
        guard container === currentTargetContainer,
              let session = carrySession, session.isCarrying else { return }
        feedLastPoint(session)
    }

    /// Replay the carry's last known cursor point into the engaged container's classification.
    private func feedLastPoint(_ session: LaunchpadCarrySession) {
        guard let window = session.lastWindowPoint else { return }
        if let space = carrySpace {
            currentTargetContainer?.updateExternalDrag(atContainerPoint: space.local(fromWindow: window))
        } else {
            currentTargetContainer?.updateExternalDrag(atWindowPoint: window)
        }
    }

    /// Window-space → page-local mapping through the pushed geometry (design §5); nil until the
    /// first push. Containers use this wherever their own frame chain would misread the SwiftUI
    /// paging offset — e.g. the root lift's grab-offset, which `convert` would skew by
    /// page×pageWidth on every page but the first.
    func pageLocalPoint(fromWindow w: NSPoint) -> NSPoint? {
        carrySpace?.local(fromWindow: w)
    }

    /// Equatable-deduped push from the grid's viewport relay (AppKit window space).
    func syncGeometry(_ new: LaunchpadPageGeometry) {
        guard new != geometry else { return }
        // Mid-carry geometry mutation (window resize / column reflow) invalidates the calibration
        // space the whole carry is mapped through — fail safe by cancelling, never by trying to
        // re-calibrate mid-flight (design §5.2 / §9.1 row 8). Page-COUNT changes alone are fine
        // (catalog reload mid-carry is tolerated, row 5).
        if carrySession != nil, geometry.pageWidth > 0,
           new.pageWidth != geometry.pageWidth || new.perPage != geometry.perPage {
            cancelCarry(.geometryChanged)
        }
        geometry = new
        scheduleGeometryProbe()
    }

    // Test-facing read-only surface (design §10-④).
    var hasFloatingWindow: Bool { carrySession?.presenter.isPresenting ?? false }
    var registeredPageIndices: [Int] { pages.filter { $0.value.value != nil }.keys.sorted() }

    // MARK: - Carry session lifecycle (design §1)

    /// Freeze the visible root order (+ editability) for the NEXT carry. Called from the host
    /// view's `onDragBegan` — the only point with access to `filtered`/`isLayoutEditable` — so
    /// the session can adopt both at lift without the coordinator reaching into the view.
    func freezeVisibleOrder(_ order: [LaunchpadDisplayCell], editable: Bool = true) {
        pendingFrozenOrder = order
        pendingEditable = editable
        carryCancelledThisGesture = false      // a new gesture starts with a clean slate
    }

    /// New-gesture boundary. `beginDirectDrag` fires exactly once per mouse gesture (the cell's
    /// `didDrag` threshold latch), so the container reports it here FIRST: the cancelled-gesture
    /// latch protects one gesture's orphan events and must not leak into the next — left set, it
    /// would make `canBeginCarry` refuse the next root lift before `onDragBegan` (the legacy
    /// reset point) could ever run, permanently swallowing root drags after any mid-carry
    /// cancel. Pure coordinator state — a refused lift still leaves the container untouched
    /// (BR-4), and the same-gesture late-begin paths (`commitOut` / a re-armed eject) never pass
    /// through `beginDirectDrag`, so they stay latched.
    func gestureBegan() {
        carryCancelledThisGesture = false
        // A new drag gesture starting while a settle flight is airborne: force-complete it NOW —
        // BEFORE the container stages any lift state — so the dying session's reveal cleans the
        // OLD anchor, never the cell the new gesture is about to park (§1.2 settling × lift).
        forceCompleteSettleIfNeeded()
    }

    /// Container-side step-0 gate (design §2.1-1 / BR-4): a refused lift must leave the container
    /// with ZERO state changes, so the container asks here BEFORE touching its own state.
    /// A SETTLING session does not refuse — iOS lets you re-grab immediately; `beginCarry`
    /// force-completes the flight first (§1.2 settling × lift).
    var canBeginCarry: Bool { carrySession?.isCarrying != true && !carryCancelledThisGesture }

    /// Begin a carry: raise the floating icon at the cursor and start make-way/merge on the
    /// visible page. Safe to call from a mouse handler — the floating window is pure AppKit, and
    /// the `@Published` flips schedule the SwiftUI folder close asynchronously.
    /// `grabOffset` keeps the lift from visually jumping (root lift; eject stays centred);
    /// `sourceContainer` is the root page holding the parked anchor cell (root origin only).
    @discardableResult
    func beginCarry(itemID: String, origin: LaunchpadCarrySession.Origin, isApp: Bool,
                    icon: NSImage?, iconSide: CGFloat,
                    atScreenPoint p: NSPoint, aboveLevel: NSWindow.Level,
                    grabOffset: NSPoint = .zero,
                    sourceContainer: LaunchpadGridContainerView? = nil) -> Bool {
        guard canBeginCarry else {
            Self.carryTrace("beginCarry REJECTED id=\(itemID) hasSession=\(carrySession != nil) cancelledThisGesture=\(carryCancelledThisGesture)")
            return false
        }
        // Re-lift while the previous settle is still flying (§1.2 settling × lift): fast-forward
        // its reveal and tear its floating icon down, then open the new session. Grid-routed
        // lifts already did this at `gestureBegan`; this covers the direct entries (late eject).
        forceCompleteSettleIfNeeded()
        Self.carryTrace("beginCarry id=\(itemID) origin=\(origin) editable=\(pendingEditable) frozen=\(pendingFrozenOrder.count) page=\(currentPage) container=\(pages[currentPage]?.value != nil)")
        let session = LaunchpadCarrySession(
            itemID: itemID,
            origin: origin,
            isApp: isApp,
            editableAtBegin: pendingEditable,
            frozenVisibleOrder: pendingFrozenOrder,
            presenter: floatingPresenterFactory(),
            grabOffset: grabOffset,
            presentedIconSide: iconSide * 1.1,
            sourceContainer: sourceContainer
        )
        pendingFrozenOrder = []
        pendingEditable = true
        session.presenter.present(icon: icon, side: iconSide * 1.1,
                                  atScreenPoint: NSPoint(x: p.x - grabOffset.x, y: p.y - grabOffset.y),
                                  aboveLevel: aboveLevel)
        carrySession = session
        engage(pages[currentPage]?.value, page: currentPage, session: session)  // visible page makes way / can merge
        session.dwellTimer = dwellTimerFactory { [weak self] in self?.tickDwell() }
        endReason = nil
        carryActive = true
        if case .folder = origin { folderEjectActive = true }
        return true
    }

    /// Follow the cursor: move the floating icon (screen space) AND drive the visible page's
    /// make-way / merge classification. The window point is mapped to page-local space through the
    /// pushed geometry — NOT through `convert` against the page container, whose frame chain is
    /// blind to the SwiftUI paging `.offset` (off by page×pageWidth on page > 0).
    func carryMoved(atScreenPoint screen: NSPoint, atWindowPoint window: NSPoint) {
        guard let session = carrySession, session.isCarrying else { return }
        session.lastScreenPoint = screen
        session.lastWindowPoint = window
        // The floating ICON stays on the overlay's screen even when the locked mouse gesture
        // wanders past its edges (iOS keeps the dragged icon on-screen). Only the presented
        // window is clamped — classification and the edge turner keep the REAL cursor point,
        // or the edge make-way/flip judgement would drift near the borders.
        var centre = NSPoint(x: screen.x - session.grabOffset.x,
                             y: screen.y - session.grabOffset.y)
        if let bounds = carryClampBounds(for: session) {
            centre = Self.clampedIconCentre(centre, side: session.presentedIconSide, in: bounds)
        }
        session.presenter.move(toScreenPoint: centre)
        guard let space = carrySpace else {                      // geometry not pushed yet (cold start)
            if case .carrying(.tracking) = session.state {
                currentTargetContainer?.updateExternalDrag(atWindowPoint: window)
            }
            return
        }
        let local = space.local(fromWindow: window)
        driveTurner(session, local: local, space: space)         // fed in BOTH carrying modes (§4.2)
        // While a flip is in flight (.awaitingHandoff) only the floating icon follows — the old
        // page slides out clean, classification resumes when the target container takes over.
        guard case .carrying(.tracking) = session.state else { return }
        crossCheckGeometry(space: space)
        currentTargetContainer?.updateExternalDrag(atContainerPoint: local)
    }

    /// Screen-space bounds the floating icon may occupy: the overlay window's screen (the overlay
    /// covers it fully, menu bar included, so `frame` — not `visibleFrame`, whose menu-bar/Dock
    /// cuts would carve unreachable dead zones out of a fullscreen overlay). Compact mode clamps
    /// to the same screen, NOT the panel: dragging out of the panel and releasing is the legal
    /// "land at the global tail" gesture, and pinning the icon to the panel edge would kill the
    /// cursor-following feel. nil (windowless harness / unmounted container) = no clamp — a
    /// production carry always starts from a mounted container, and tests pin exact coordinates.
    private func carryClampBounds(for session: LaunchpadCarrySession) -> NSRect? {
        guard let window = (currentTargetContainer ?? session.sourceContainer)?.window else { return nil }
        return window.screen?.frame ?? window.frame
    }

    /// Pure clamp of the floating icon's CENTRE so the icon rect stays inside `bounds`;
    /// degenerate bounds (narrower than the icon) pin to the midline instead of oscillating.
    static func clampedIconCentre(_ centre: NSPoint, side: CGFloat, in bounds: NSRect) -> NSPoint {
        let half = side / 2
        let x = bounds.width <= side
            ? bounds.midX
            : min(max(centre.x, bounds.minX + half), bounds.maxX - half)
        let y = bounds.height <= side
            ? bounds.midY
            : min(max(centre.y, bounds.minY + half), bounds.maxY - half)
        return NSPoint(x: x, y: y)
    }

    /// Stationary-cursor drive: mouseDragged stops arriving when the cursor holds still, so the
    /// 30Hz tick replays the last point into the dwell machine (never into classification — a
    /// stationary cursor can't change the gap). O(1), no IO (constraint 22).
    func tickDwell() {
        guard let session = carrySession, session.isCarrying,
              let window = session.lastWindowPoint, let space = carrySpace else { return }
        driveTurner(session, local: space.local(fromWindow: window), space: space)
    }

    private func driveTurner(_ session: LaunchpadCarrySession, local: NSPoint, space: LaunchpadCarrySpace) {
        // Outer-column exemption (§A5): the cursor sitting on an edge COLUMN is aiming a drop —
        // only the bare margin / past-the-page strip may arm a flip. Container-local x IS
        // page-local x ("viewport is the page"); during .awaitingHandoff the old container is
        // still engaged, but every page shares the same column geometry, so the bands hold.
        let spans = currentTargetContainer?.outerColumnXSpans()
        let decision = session.turner.update(
            point: local, pageWidth: space.pageWidth, now: now(),
            exempt: .init(left: spans?.left, right: spans?.right))
        guard case .flip(let direction) = decision else { return }
        let target = currentTargetPage + direction
        // The flippable range includes the virtual tail index (== pageCount) while the carry can
        // edit the layout — mirroring the grid's displayPageCount (§6.1). An out-of-range flip is
        // simply dropped: the turner is already in cooldown and will retry on cadence.
        let lastFlippable = session.editableAtBegin ? geometry.pageCount : geometry.pageCount - 1
        guard target >= 0, target <= lastFlippable else { return }
        session.awaitHandoff(targetPage: target)
        flipToken += 1
        flipRequest = LaunchpadFlipRequest(token: flipToken, targetPage: target)
    }

    /// mouseUp: resolve the drop, land the DATA synchronously through `storeApplier`, then start
    /// the purely visual settle — a 0.25s floating-icon flight into the resolved slot when a
    /// flyable rect exists, the legacy hard-cut teardown otherwise (design §1.4/§7).
    func carryReleased(atWindowPoint p: NSPoint) {
        guard let session = carrySession, session.isCarrying else {
            Self.carryTrace("carryReleased NO-SESSION p=\(p)")
            return
        }
        withdrawDwell(session)                               // a flip must never land post-release (§1.4-4)

        // Resolve exactly as the legacy eject commit did: a `.reorder(nil)` means classification
        // never settled (the whole carry stayed in the columns' central dead-band) — re-resolve
        // from the RELEASE point so an in-grid drop never falls back to the tail.
        let releaseTarget: LaunchpadDropTarget?
        if let space = carrySpace {
            releaseTarget = currentTargetContainer?.rootDropTarget(atContainerPoint: space.local(fromWindow: p))
        } else {
            releaseTarget = currentTargetContainer?.rootDropTarget(atWindowPoint: p)
        }
        var result = currentTargetContainer?.resolveExternalDrop() ?? .reorder(releaseTarget)
        if case .reorder(nil) = result { result = .reorder(releaseTarget) }
        // Peek the flight target while the gap/merge state is still alive (pure peek, §7.1) —
        // the freeze below clears it. nil = no flyable slot: an ENGAGED-BUT-EMPTY container
        // (production: the virtual tail page, whose collapse + §6.2 snap-back would race the
        // flight — see settleTargetLocalRect), no engaged container at all, a windowless
        // harness, or classification that never settled. All of those degrade to the hard-cut
        // dismiss further down — the deliberate choice over an in-place fade: the icon vanishes
        // at the cursor and the landed cell reveals in the same mouseUp stack.
        var settleScreenRect = settleTargetScreenRect()
        Self.carryTrace("carryReleased p=\(p) target=\(String(describing: releaseTarget)) result=\(result) engaged=\(currentTargetContainer != nil) editable=\(session.editableAtBegin) settleRect=\(String(describing: settleScreenRect))")

        // DATA lands here, synchronously in mouseUp. Editability uses the value frozen at lift —
        // a live isLayoutEditable check could drop a commit landing after typing flattened the
        // layout to search (BR-2).
        let action: CarryStoreAction = session.editableAtBegin
            ? Self.resolveCarryCommit(
                LaunchpadCarryCommit(itemID: session.itemID, origin: session.origin, result: result),
                frozenOrder: session.frozenVisibleOrder)
            : .none
        var landingID: String?
        Self.carryTrace("carryReleased action=\(action) applier=\(storeApplier != nil) frozen=\(session.frozenVisibleOrder.count)")
        if action != .none {
            if let storeApplier {
                landingID = storeApplier(action, session.frozenVisibleOrder)
            } else {
                // Production always injects the applier in the overlay controller's init. Reaching
                // here means that wiring regressed: the commit's DATA is being dropped while the
                // visual token below still fires — the exact silent-loss class this step exists to
                // kill. Loud, not fatal: the legacy eject shims legitimately run applier-less in
                // tests (token/pendingEject assertions).
                Self.logger.fault("carry commit resolved to a store action but no storeApplier is injected — data dropped")
            }
        }

        // BR-3b cross-page degrade (§8): the commit channel re-anchors the viewport to the
        // LANDING page (relocateSelection + the pageCount clamp run off commitToken). When the
        // committed landing falls on a DIFFERENT page than the drop viewport — a gap-0 drop on
        // a later page shifts the landing index back across the page boundary; a merge that
        // swallows the last page's lone item shrinks pageCount — those writes slide/clamp the
        // pager while the 0.25s flight is still airborne: the exact "floating icon lands on a
        // page that just slid away" failure the settling freeze exists to prevent. Same degrade
        // family as the empty-virtual-page and gap≥capacity cases: hard-cut, reveal in the
        // mouseUp stack. An unpredictable landing (stale ids, no geometry) keeps the flight —
        // the prediction replays the same frozen order the commit itself resolved against.
        if settleScreenRect != nil, let landedID = landingID, geometry.perPage > 0,
           let landingIndex = Self.predictedLandingIndex(action: action, landingID: landedID,
                                                         frozenOrder: session.frozenVisibleOrder),
           landingIndex / geometry.perPage != currentTargetPage {
            Self.carryTrace("settle DEGRADE cross-page landing idx=\(landingIndex) " +
                            "page=\(landingIndex / geometry.perPage) targetPage=\(currentTargetPage)")
            settleScreenRect = nil
        }

        // Folder commits flip the target cell from a single app icon to a composed folder
        // thumbnail. Flying the lone dragged-app icon for the 0.25s settle before revealing
        // that thumbnail reads as "the dragged app, then a beat later the folder" — the
        // not-snappy lag. Hard-cut these so the composed folder thumbnail appears in this
        // same mouseUp stack (the data already landed above). Reorders keep their flight.
        switch result {
        case .makeFolder, .addToFolder:
            settleScreenRect = nil
        case .reorder:
            break
        }

        pendingVisualCommit = VisualCommit(itemID: session.itemID, origin: session.origin,
                                           result: result, landingID: landingID)

        if let settleScreenRect {
            // FLIGHT settle (design §1.4-6..9): data is already safe; everything below is pure
            // visual choreography. The session survives in `.settling` — every input-freeze gate
            // keys on `carrySession != nil`, so manual page flips stay frozen for the 0.25s
            // flight (§8/BR-3b) — while `isCarrying == false` keeps registration/funnel/apply
            // paths from re-engaging a dying carry (§1.2 settling row).
            settleGeneration += 1
            let generation = settleGeneration
            // Park-by-id for the flight: normally the carried item's own id — but a MAKE-FOLDER
            // commit replaces the target app's cell with a brand-new folder cell (fresh UUID)
            // and the dragged app keeps no top-level cell at all, so the cell to park is the
            // NEW FOLDER (landingID; covers the root merge and the eject-into-new-folder, both
            // of which return the new folder's id). It must stay limited to makeFolder:
            // addToFolder's landingID is an EXISTING folder cell that must remain visible, and
            // a reorder's landingID is the item id anyway.
            if case .makeFolder = result, let landingID {
                settlingItemID = landingID
            } else {
                settlingItemID = session.itemID
            }
            session.beginSettling(generation: generation)
            // Freeze, don't end: the make-way frames hold still so the post-commit apply — whose
            // committed layout is slot-for-slot identical to the gap layout — lands with zero
            // motion (§7.3-1). The source anchor stays parked (endCarryAnchor is the reveal's
            // job): its deferred apply must stay deferred too, or the stale pre-commit model
            // would reflow the board mid-flight and the fresh one snap it right back.
            currentTargetContainer?.freezeExternalDrag()
            currentTargetContainer = nil
            endReason = .committed
            folderEjectActive = false
            carryActive = false                              // virtual tail page retracts now
            commitToken += 1                                 // visual-only; data is already safe
            // The created-folder reveal rides the settle: staged here, published when the
            // flight's reveal runs (finishSettle) — natural completion, watchdog or
            // force-complete alike (the view's guards absorb the force-complete cases).
            pendingRevealFolderID = pendingVisualCommit?.createdFolderID
            // Watchdog BEFORE the flight: a spy presenter completes synchronously, and the
            // finish below must find (and cancel) the scheduled work, not race its scheduling.
            settleTimeoutWork = settleTimeoutScheduler(settleTimeoutInterval) { [weak self] in
                self?.settleFinished(generation)
            }
            session.presenter.settle(to: settleScreenRect) { [weak self] in
                self?.settleFinished(generation)
            }
        } else {
            // HARD-CUT settle (degenerate branch — preserved verbatim from step 7): no flyable
            // rect, so reveal everything in the mouseUp stack. Order matters: the session ends
            // FIRST so the anchor reveal below — which may run a deferred apply → registration →
            // reattach — finds no live carry to re-engage; the anchor is revealed BEFORE the gap
            // settles so the settle's layout already includes the revealed cell (a no-op drop
            // glides it straight back into its original slot — AR-1: the reveal pipeline runs
            // unconditionally).
            carrySession = nil
            session.sourceContainer?.endCarryAnchor()        // root origin: un-park the anchor cell
            currentTargetContainer?.endExternalDrag()        // gap settles closed
            currentTargetContainer = nil
            session.presenter.dismiss()
            endReason = .committed
            folderEjectActive = false
            carryActive = false
            commitToken += 1                                 // visual-only; data is already safe
            // Hard-cut reveals everything in this same mouseUp stack — publish the created-
            // folder reveal now (there is no flight whose reveal could carry it later).
            publishFolderReveal(pendingVisualCommit?.createdFolderID)
        }
    }

    /// Publish the post-creation auto-open trigger (design §2.6). Tokenised so the grid view's
    /// `.onChange` fires even for back-to-back creations of distinct folders.
    private func publishFolderReveal(_ folderID: String?) {
        guard let folderID else { return }
        revealedFolderID = folderID
        folderRevealToken += 1
    }

    /// The screen rect the floating icon should fly to: the engaged container's armed/gap slot
    /// (container-local, pure peek) → window space through the pushed CarrySpace arithmetic
    /// ("viewport is the page" — container coords ARE page-local coords for the visible page) →
    /// screen space through `NSWindow.convertToScreen` (a window-level conversion the SwiftUI
    /// paging offset can't pollute). nil whenever any link is missing — the release then takes
    /// the hard-cut branch.
    private func settleTargetScreenRect() -> NSRect? {
        guard let container = currentTargetContainer,
              let window = container.window,
              let space = carrySpace,
              let local = container.settleTargetLocalRect() else { return nil }
        return window.convertToScreen(space.windowRect(fromLocal: local))
    }

    /// Flight completion, watchdog, and force-complete all converge here. The generation kills
    /// stale callbacks: a completion armed before a force-complete — or for an earlier session —
    /// must never tear down a newer session's floating icon or un-park its cells (AR-6).
    private func settleFinished(_ generation: Int) {
        guard let session = carrySession,
              case .settling(let current) = session.state,
              current == generation else { return }
        // Natural completion / watchdog: the icon already covers the slot, so the dismiss can
        // wait one turn for the revealed cell's first paint (deferDismiss). Force-complete and
        // cancel must NOT defer — a re-lift presents the next session's window in the same
        // stack, and an overlay teardown must not leave a floating window behind.
        finishSettle(session, deferDismiss: true)
    }

    /// Fast-forward an airborne settle (§1.2 settling row): re-lift, any cancel reason, and the
    /// overlay closing all complete the visuals immediately. The data landed at mouseUp — nothing
    /// here writes or loses anything.
    private func forceCompleteSettleIfNeeded() {
        guard let session = carrySession, case .settling = session.state else { return }
        Self.carryTrace("settle force-complete gen=\(settleGeneration)")
        finishSettle(session)
    }

    /// The reveal (design §7.3-3/4), fully synchronous: end the session, clear the park predicate,
    /// give the source anchor its one-shot deferred apply, lay every parked cell into its real
    /// slot, then drop the floating icon — which is sitting exactly on that slot, so the swap is
    /// invisible. Ordering notes: the session ends FIRST (apply/registration during the reveal
    /// must find no live carry); `settlingItemID` clears BEFORE any layout pass so the predicate
    /// stops excluding the landed cell; the icon dismisses LAST so the cell is already on screen
    /// — and on the natural-completion path one runloop turn later still (`deferDismiss`), so
    /// the revealed cell's first PAINT (this turn's CA commit) lands before `orderOut` reaches
    /// the window server. Each session owns its own presenter, so a deferred dismiss can never
    /// touch a newer session's window.
    private func finishSettle(_ session: LaunchpadCarrySession, deferDismiss: Bool = false) {
        settleTimeoutWork?.cancel()
        settleTimeoutWork = nil
        carrySession = nil
        settlingItemID = nil
        session.sourceContainer?.endCarryAnchor()            // root origin: un-park + apply pendingGrid
        for (_, boxed) in pages { boxed.value?.revealSettledCell() }
        if deferDismiss {
            let presenter = session.presenter
            settleDismissScheduler { presenter.dismiss() }
        } else {
            session.presenter.dismiss()
        }
        // The reveal is done — the landed cell owns its slot, so the folder panel can mount
        // without fighting the park predicate. Consumed-once: cleared before publishing.
        let revealFolderID = pendingRevealFolderID
        pendingRevealFolderID = nil
        publishFolderReveal(revealFolderID)
    }

    /// Abort an in-flight carry (launcher closed / source unmounted / search activated) without
    /// moving anything. Fully synchronous — never routed through a `@Published` token, so the
    /// teardown does not depend on the view tree surviving (design §9.2). Nil-safe: a cancel with
    /// no session is ignored. `reason` gains distinct behaviour in later steps (page clamp etc.).
    func cancelCarry(_ reason: CarryCancelReason) {
        guard let session = carrySession else { return }
        if case .settling = session.state {
            // The drop already committed at mouseUp — a cancel mid-flight (overlay closing,
            // typing, geometry change) only FAST-FORWARDS the visuals: reveal now, drop the
            // floating icon, keep `.committed`. No write happens, none is lost (§1.2/§9.1 row 7),
            // and no orphan-gesture latch: the settling gesture's mouseUp already arrived.
            Self.carryTrace("cancelCarry reason=\(reason) during settling → force-complete")
            finishSettle(session)
            return
        }
        Self.carryTrace("cancelCarry reason=\(reason)")
        carryCancelledThisGesture = true
        withdrawDwell(session)
        // Session ends FIRST: the anchor restore below runs apply/registration paths that must
        // not re-engage a dying carry (reattach / containerDidApplyCells key on carrySession).
        carrySession = nil
        session.sourceContainer?.cancelCarryAnchor()         // root origin: instant in-place restore
        currentTargetContainer?.endExternalDrag()
        currentTargetContainer = nil
        session.presenter.dismiss()
        endReason = .cancelled
        folderEjectActive = false
        carryActive = false
    }

    /// Stop the dwell tick and withdraw any unconsumed flip request — shared by every carry exit.
    private func withdrawDwell(_ session: LaunchpadCarrySession) {
        session.dwellTimer?.invalidate()
        session.dwellTimer = nil
        if flipRequest != nil { flipRequest = nil }
    }

    /// Pure mapping: container resolution + origin → store action (design §1.3). Static so unit
    /// tests drive every branch without a session or a window.
    static func resolveCarryCommit(_ commit: LaunchpadCarryCommit,
                                   frozenOrder: [LaunchpadDisplayCell]) -> CarryStoreAction {
        switch commit.origin {
        case .folder(let folderID):
            // The store's moveOutOfFolder family already handles nil-target tail drops and the
            // 2-app dissolve target redirect — pass the result through untouched.
            return .moveOutOfFolder(folderID: folderID, appID: commit.itemID, result: commit.result)
        case .rootPage:
            switch commit.result {
            case .makeFolder(let targetAppID):
                return .makeFolder(targetAppID: targetAppID, draggedID: commit.itemID)
            case .addToFolder(let folderID):
                return .addToFolder(folderID: folderID, appID: commit.itemID)
            case .reorder(let target?):
                let order = frozenOrder.map(\.layoutID)
                guard !target.isNoOp(dragged: commit.itemID, in: order) else { return .none }
                return .move(id: commit.itemID, target: target)
            case .reorder(nil):
                // Out-of-grid release = land at the global tail; already last = no-op. The tail
                // node may be a folder — `move(after: folderID)` is a valid existing operation.
                guard let last = frozenOrder.last, last.layoutID != commit.itemID else { return .none }
                return .move(id: commit.itemID, target: .after(last.layoutID))
            }
        }
    }

    /// Predicts the landing cell's flat index in the COMMITTED visible order by replaying the
    /// resolved store action over the order frozen at drag start — the same premise the settle
    /// flight already rests on (§7.3-1: the store materializes from this very order, so the
    /// committed board is the frozen board with the action applied). Insert semantics mirror
    /// `LaunchpadLayoutStore`: remove first, a stale target appends at the tail, a make-folder
    /// replaces the target's slot, and a dissolving 2-app source folder swaps to its survivor
    /// IN PLACE — which leaves every flat index unchanged, so targets that referenced the folder
    /// id still resolve to the right slot. Returns nil when the landing id cannot be located;
    /// callers treat that as "unknown" and keep today's behaviour. Pure and static so unit
    /// tests drive every branch without a session or a window.
    static func predictedLandingIndex(action: CarryStoreAction, landingID: String,
                                      frozenOrder: [LaunchpadDisplayCell]) -> Int? {
        var ids = frozenOrder.map(\.layoutID)
        func insert(_ id: String, at target: LaunchpadDropTarget?) {
            switch target {
            case .before(let t):
                if let i = ids.firstIndex(of: t) { ids.insert(id, at: i) } else { ids.append(id) }
            case .after(let t):
                if let i = ids.firstIndex(of: t) { ids.insert(id, at: i + 1) } else { ids.append(id) }
            case nil:
                ids.append(id)
            }
        }
        switch action {
        case .none:
            return nil
        case .move(let id, let target):
            ids.removeAll { $0 == id }
            insert(id, at: target)
        case .makeFolder(let targetAppID, let draggedID):
            ids.removeAll { $0 == draggedID }
            guard let i = ids.firstIndex(of: targetAppID) else { return nil }
            ids[i] = landingID
        case .addToFolder(_, let appID):
            // Landing is the EXISTING destination folder; only the dragged root cell leaves.
            ids.removeAll { $0 == appID }
        case .moveOutOfFolder(_, let appID, let result):
            // The carried app has no root cell while folder-borne; the source folder either
            // shrinks (its cell stays) or dissolves into its survivor (positional swap) —
            // root flat indices are unaffected either way.
            switch result {
            case .reorder(let target):
                insert(appID, at: target)
            case .makeFolder(let targetAppID):
                guard let i = ids.firstIndex(of: targetAppID) else { return nil }
                ids[i] = landingID
            case .addToFolder:
                break
            }
        }
        return ids.firstIndex(of: landingID)
    }

    // MARK: - Legacy eject API (thin shims — design §0 naming table; existing tests + the
    // container's call sites keep compiling unchanged)

    struct EjectRequest {
        let folderID: String
        let appID: String
        let result: LaunchpadExternalDropResult
    }

    var ejectActive: Bool { folderEjectActive }
    var ejectToken: Int { commitToken }

    var pendingEject: EjectRequest? {
        guard let visual = pendingVisualCommit,
              case .folder(let folderID) = visual.origin else { return nil }
        return EjectRequest(folderID: folderID, appID: visual.itemID, result: visual.result)
    }

    /// The app currently being carried out of a folder + its source — used to hide it from that
    /// folder's thumbnail during the carry (transient display only; data lands at release).
    var carriedAppID: String? {
        guard let session = carrySession, case .folder = session.origin else { return nil }
        return session.itemID
    }

    var carriedSourceFolderID: String? {
        guard let session = carrySession, case .folder(let folderID) = session.origin else { return nil }
        return folderID
    }

    func beginEject(appID: String, sourceFolderID: String, icon: NSImage?, iconSide: CGFloat,
                    atScreenPoint p: NSPoint, aboveLevel: NSWindow.Level) {
        beginCarry(itemID: appID, origin: .folder(sourceFolderID: sourceFolderID), isApp: true,
                   icon: icon, iconSide: iconSide, atScreenPoint: p, aboveLevel: aboveLevel)
    }

    func moveEject(atScreenPoint screen: NSPoint, atWindowPoint window: NSPoint) {
        carryMoved(atScreenPoint: screen, atWindowPoint: window)
    }

    func commitOut(folderID: String, appID: String, atWindowPoint p: NSPoint) {
        if carrySession == nil {
            Self.carryTrace("commitOut LATE-BEGIN folder=\(folderID) app=\(appID)")
            // Late eject: the release point itself is the first clearly-outside point (no
            // updateDirectDrag classified in between, e.g. windowless tests or a single fast
            // mouse delta), so no session was begun. Open one and commit it immediately — the
            // floating icon is presented and dismissed within the same runloop turn (never drawn).
            beginCarry(itemID: appID, origin: .folder(sourceFolderID: folderID), isApp: true,
                       icon: nil, iconSide: 0, atScreenPoint: p, aboveLevel: .normal)
        }
        carryReleased(atWindowPoint: p)
    }

    func cancelEject() {
        cancelCarry(.shutdown)
    }

    // MARK: - Debug geometry probe

    #if DEBUG
    /// Lets a runtime session validate the geometry push by just opening the launcher and flipping
    /// pages (no folder-eject choreography needed). Delayed a tick so layout settles first.
    private func scheduleGeometryProbe() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, let space = self.carrySpace else { return }
            self.crossCheckGeometry(space: space)
        }
    }

    /// Cross-checks the pushed viewport against a frame-chain derivation (registered container's
    /// window origin − page×pageWidth). Frame chains ignore the paging offset, which is exactly
    /// why both derivations must agree on the viewport. Discrepancies land in a /tmp log (dev
    /// plugin OSLog isn't capturable) — runtime validation gate for design §5, retire at step 9.
    private var lastProbeAt: CFTimeInterval = 0
    private func crossCheckGeometry(space: LaunchpadCarrySpace) {
        let now = CACurrentMediaTime()
        guard now - lastProbeAt > 0.25 else { return }
        lastProbeAt = now
        guard let container = activeContainer, container.window != nil else { return }
        let origin = container.convert(NSPoint.zero, to: nil)    // container top-left in window space
        let derivedMinX = origin.x - CGFloat(currentPage) * space.pageWidth
        let dx = abs(derivedMinX - space.viewportMinX), dy = abs(origin.y - space.viewportTopY)
        let line = "page=\(currentPage) pushed=(\(space.viewportMinX),\(space.viewportTopY)) " +
                   "derived=(\(derivedMinX),\(origin.y)) d=(\(dx),\(dy))\n"
        let probePath = Self.probePath
        Self.probeQueue.async {
            guard let data = line.data(using: .utf8),
                  let handle = FileHandle(forWritingAtPath: probePath) ?? Self.createProbeLog(atPath: probePath) else { return }
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    }

    private static let probeQueue = DispatchQueue(label: "launchpad.geometry-probe", qos: .utility)
    private static let probePath = "/tmp/launchpad-geometry-probe.log"

    /// TEMP diagnostic trace for the carry chain (runtime verification of §11 steps 2-6; remove at
    /// step 9). Same /tmp channel as the probe — dev-app OSLog is not capturable on this machine.
    static func carryTrace(_ line: String) {
        let stamped = "\(String(format: "%.3f", CACurrentMediaTime())) \(line)\n"
        probeQueue.async {
            let path = "/tmp/launchpad-carry-trace.log"
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            guard let handle = FileHandle(forWritingAtPath: path), let data = stamped.data(using: .utf8) else { return }
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    }
    private nonisolated static func createProbeLog(atPath path: String) -> FileHandle? {
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }
    #else
    private func scheduleGeometryProbe() {}
    private func crossCheckGeometry(space: LaunchpadCarrySpace) {}
    static func carryTrace(_ line: String) {}
    #endif
}
