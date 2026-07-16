import AppKit
import Combine
import SwiftUI
import MacToolsPluginKit

enum MenuBarPanelWindowRegistry {
    private static let secondaryPanelIdentifier = NSUserInterfaceItemIdentifier(
        "MacTools.MenuBarSecondaryPanel"
    )

    @MainActor
    static func markSecondaryPanel(_ window: NSWindow) {
        window.identifier = secondaryPanelIdentifier
    }

    @MainActor
    static func containsAuxiliaryPanelWindow(_ window: NSWindow) -> Bool {
        window.identifier == secondaryPanelIdentifier
    }
}

@MainActor
final class MenuBarPanelPresenter: NSObject {
    static let popoverBehavior: NSPopover.Behavior = .applicationDefined

    private enum PanelKind: Equatable {
        case features
        case components
    }

    private let pluginHost: PluginHost
    private let onDismiss: () -> Void
    private let onOpenSettings: () -> Void
    private let onPresentDiskCleanConfiguration: () -> Void
    private let onPresentLaunchControlConfiguration: () -> Void
    private let onAllPanelsClosed: () -> Void

    private let popover = NSPopover()
    private let panelModel: MenuBarUnifiedPanelModel
    private let hostingController: NSHostingController<MenuBarUnifiedPanelContent>
    private var appearanceObserver: NSObjectProtocol?
    private var runtimeLocaleCancellable: AnyCancellable?
    private var heightRefreshCancellables: Set<AnyCancellable> = []
    private var selectedPanel: PanelKind = .components

    init(
        pluginHost: PluginHost,
        onDismiss: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onPresentDiskCleanConfiguration: @escaping () -> Void,
        onPresentLaunchControlConfiguration: @escaping () -> Void,
        onAllPanelsClosed: @escaping () -> Void
    ) {
        self.pluginHost = pluginHost
        self.onDismiss = onDismiss
        self.onOpenSettings = onOpenSettings
        self.onPresentDiskCleanConfiguration = onPresentDiskCleanConfiguration
        self.onPresentLaunchControlConfiguration = onPresentLaunchControlConfiguration
        self.onAllPanelsClosed = onAllPanelsClosed

        let panelModel = MenuBarUnifiedPanelModel(
            selectedTab: .components,
            contentHeight: MenuBarPanelLayout.minimumContentHeight,
            maximumFeatureListHeight: MenuBarPanelLayout.maximumFeatureListHeight(for: nil),
            isPanelVisible: false
        )
        self.panelModel = panelModel
        self.hostingController = NSHostingController(
            rootView: MenuBarUnifiedPanelContent(
                pluginHost: pluginHost,
                model: panelModel,
                onDismiss: onDismiss,
                onOpenSettings: onOpenSettings,
                onPresentDiskCleanConfiguration: onPresentDiskCleanConfiguration,
                onPresentLaunchControlConfiguration: onPresentLaunchControlConfiguration
            )
        )

        super.init()

        panelModel.onTabSelection = { [weak self] tab in
            self?.select(tab)
        }
        configure(popover)
        observeAppearancePreference()
        runtimeLocaleCancellable = PluginRuntimeLocalization.source.$revision
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshLocalization()
                }
            }
        observePanelItemChanges()
        applyCurrentAppearance()
        prewarm()
        scheduleComponentViewPrewarm()
    }

    isolated deinit {
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
        runtimeLocaleCancellable?.cancel()
    }

    var isAnyPanelShown: Bool {
        popover.isShown
    }

    private func refreshLocalization() {
        hostingController.rootView = MenuBarUnifiedPanelContent(
            pluginHost: pluginHost,
            model: panelModel,
            onDismiss: onDismiss,
            onOpenSettings: onOpenSettings,
            onPresentDiskCleanConfiguration: onPresentDiskCleanConfiguration,
            onPresentLaunchControlConfiguration: onPresentLaunchControlConfiguration
        )
        scheduleHeightRefresh(for: tab(for: selectedPanel))
    }

    #if DEBUG
    var debugPopoverForTests: NSPopover {
        popover
    }
    #endif

    func toggleFeaturePanel(relativeTo button: NSStatusBarButton) {
        toggle(.features, relativeTo: button)
    }

    func toggleComponentPanel(relativeTo button: NSStatusBarButton) {
        toggle(.components, relativeTo: button)
    }

    func dismissPanels() {
        popover.performClose(nil)
    }

    func containsPresentedWindow(_ window: NSWindow) -> Bool {
        window === popover.contentViewController?.view.window
            || MenuBarPanelWindowRegistry.containsAuxiliaryPanelWindow(window)
    }

    private func toggle(_ panel: PanelKind, relativeTo button: NSStatusBarButton) {
        if popover.isShown, selectedPanel == panel {
            popover.performClose(nil)
            return
        }

        let wasShown = popover.isShown
        selectedPanel = panel
        updateContent(
            selectedTab: tab(for: panel),
            screen: button.window?.screen ?? NSScreen.main,
            isPanelVisible: true
        )
        updatePanelSurfaceVisibility(for: tab(for: panel), isPanelVisible: true)

        if wasShown {
            focus(popover)
            scheduleHeightRefresh(for: tab(for: panel))
            return
        }

        show(popover, relativeTo: button)
        scheduleHeightRefresh(for: tab(for: panel))
    }

    private func configure(_ popover: NSPopover) {
        // Dismissal is coordinated by MenuBarStatusItemController so sibling
        // panels can receive clicks without AppKit closing the popover first.
        popover.behavior = Self.popoverBehavior
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = hostingController
        // Keep popover sizing single-sourced from MenuBarPanelLayout.
        // Letting SwiftUI also publish preferredContentSize can make AppKit
        // resize the shown popover a second time during tab switches.
        if #available(macOS 14.0, *) {
            hostingController.sizingOptions = []
        }
        AppAppearancePreference.stored().apply(to: hostingController.view)
    }

    private func prewarm() {
        popover.contentSize = NSSize(
            width: MenuBarPanelLayout.baseWidth,
            height: MenuBarPanelLayout.minimumPanelHeight
        )
        hostingController.loadViewIfNeeded()
        hostingController.view.setFrameSize(popover.contentSize)
    }

    private func scheduleComponentViewPrewarm() {
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else {
                return
            }

            self.pluginHost.prewarmComponentViews(dismiss: self.onDismiss)
        }
    }

    private func show(_ popover: NSPopover, relativeTo button: NSStatusBarButton) {
        applyCurrentAppearance()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        applyCurrentAppearance()
        focus(popover)
    }

    private func focus(_ popover: NSPopover) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()

        Task { @MainActor [weak popover] in
            await Task.yield()
            guard let popover, popover.isShown else {
                return
            }

            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func observeAppearancePreference() {
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: AppAppearancePreference.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyCurrentAppearance()
            }
        }
    }

    private func observePanelItemChanges() {
        pluginHost.$panelItems
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshHeightForVisiblePanel()
                }
            }
            .store(in: &heightRefreshCancellables)

        pluginHost.$componentItems
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshHeightForVisiblePanel()
                }
            }
            .store(in: &heightRefreshCancellables)
    }

    private func applyCurrentAppearance() {
        let preference = AppAppearancePreference.stored()
        preference.apply(to: hostingController.view)
        preference.apply(to: popover)
    }

    private func setPopoverHeight(_ height: CGFloat) {
        let width = MenuBarPanelLayout.baseWidth
        let currentSize = popover.contentSize
        guard
            abs(currentSize.width - width) > 0.5
                || abs(currentSize.height - height) > 0.5
        else {
            return
        }

        popover.contentSize = NSSize(width: width, height: height)
    }

    private func updateContent(
        selectedTab: MenuBarPanelTab,
        screen: NSScreen?,
        isPanelVisible: Bool
    ) {
        let heightResolution = resolveContentHeight(
            for: selectedTab,
            screen: screen
        )
        panelModel.update(
            selectedTab: selectedTab,
            contentHeight: heightResolution.contentHeight,
            maximumFeatureListHeight: heightResolution.maximumFeatureListHeight,
            isPanelVisible: isPanelVisible
        )
        setPopoverHeight(MenuBarPanelLayout.panelHeight(forContentHeight: heightResolution.contentHeight))
    }

    private func select(_ tab: MenuBarPanelTab) {
        guard tab != panelModel.selectedTab else {
            return
        }

        selectedPanel = panelKind(for: tab)
        updateContent(
            selectedTab: tab,
            screen: popover.contentViewController?.view.window?.screen ?? NSScreen.main,
            isPanelVisible: popover.isShown
        )
        updatePanelSurfaceVisibility(for: tab, isPanelVisible: popover.isShown)
        scheduleHeightRefresh(for: tab)
    }

    private func scheduleHeightRefresh(for tab: MenuBarPanelTab) {
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.popover.isShown else {
                return
            }

            self.refreshHeight(for: tab)
        }
    }

    private func refreshHeight(for tab: MenuBarPanelTab) {
        guard tab == self.tab(for: selectedPanel) else {
            return
        }

        let screen = popover.contentViewController?.view.window?.screen ?? NSScreen.main
        let heightResolution = resolveContentHeight(
            for: tab,
            screen: screen
        )
        panelModel.update(
            selectedTab: tab,
            contentHeight: heightResolution.contentHeight,
            maximumFeatureListHeight: heightResolution.maximumFeatureListHeight,
            isPanelVisible: popover.isShown
        )
        setPopoverHeight(MenuBarPanelLayout.panelHeight(forContentHeight: heightResolution.contentHeight))
    }

    private func refreshHeightForVisiblePanel() {
        guard popover.isShown else {
            return
        }

        refreshHeight(for: tab(for: selectedPanel))
    }

    private func resolveContentHeight(
        for tab: MenuBarPanelTab,
        screen: NSScreen?
    ) -> MenuBarPanelHeightResolution {
        let maximumFeatureListHeight = MenuBarPanelLayout.maximumFeatureListHeight(for: screen)

        switch tab {
        case .components:
            return MenuBarPanelHeightResolution(
                contentHeight: ComponentPanelLayout.preferredContentHeight(
                    for: pluginHost.componentItems,
                    screen: screen
                ),
                maximumFeatureListHeight: maximumFeatureListHeight
            )
        case .features:
            return MenuBarPanelHeightResolution(
                contentHeight: MenuBarPanelLayout.preferredFeatureContentHeight(
                    featureContentHeight: MenuBarPanelLayout.featureContentHeight(
                        for: pluginHost.panelItems
                    ),
                    maximumFeatureListHeight: maximumFeatureListHeight
                ),
                maximumFeatureListHeight: maximumFeatureListHeight
            )
        }
    }

    private func tab(for panel: PanelKind) -> MenuBarPanelTab {
        switch panel {
        case .features:
            return .features
        case .components:
            return .components
        }
    }

    private func panelKind(for tab: MenuBarPanelTab) -> PanelKind {
        switch tab {
        case .features:
            return .features
        case .components:
            return .components
        }
    }

    private func updatePanelSurfaceVisibility(for tab: MenuBarPanelTab, isPanelVisible: Bool) {
        pluginHost.setPanelSurface(.component, visible: isPanelVisible && tab == .components)
        pluginHost.setPanelSurface(.primary, visible: isPanelVisible && tab == .features)
    }

}

extension MenuBarPanelPresenter: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        if let closedPopover = notification.object as? NSPopover, closedPopover === popover {
            updateContent(
                selectedTab: tab(for: selectedPanel),
                screen: NSScreen.main,
                isPanelVisible: false
            )
            updatePanelSurfaceVisibility(
                for: tab(for: selectedPanel),
                isPanelVisible: false
            )
            onAllPanelsClosed()
        }
    }
}

enum MenuBarPanelTab: CaseIterable, Hashable {
    case components
    case features

    var systemImage: String {
        switch self {
        case .components:
            return "square.grid.2x2"
        case .features:
            return "switch.2"
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .components:
            return AppL10n.plugins("plugin.panel.components", defaultValue: "组件面板")
        case .features:
            return AppL10n.plugins("plugin.panel.features", defaultValue: "功能面板")
        }
    }
}

struct MenuBarPanelHeightResolution: Equatable {
    let contentHeight: CGFloat
    let maximumFeatureListHeight: CGFloat
}

@MainActor
final class MenuBarUnifiedPanelModel: ObservableObject {
    private(set) var selectedTab: MenuBarPanelTab
    private(set) var contentHeight: CGFloat
    private(set) var maximumFeatureListHeight: CGFloat
    private(set) var isPanelVisible: Bool
    var onTabSelection: ((MenuBarPanelTab) -> Void)?

    init(
        selectedTab: MenuBarPanelTab,
        contentHeight: CGFloat,
        maximumFeatureListHeight: CGFloat,
        isPanelVisible: Bool
    ) {
        self.selectedTab = selectedTab
        self.contentHeight = contentHeight
        self.maximumFeatureListHeight = maximumFeatureListHeight
        self.isPanelVisible = isPanelVisible
    }

    func update(
        selectedTab: MenuBarPanelTab,
        contentHeight: CGFloat,
        maximumFeatureListHeight: CGFloat,
        isPanelVisible: Bool
    ) {
        guard
            self.selectedTab != selectedTab
                || abs(self.contentHeight - contentHeight) > 0.5
                || abs(self.maximumFeatureListHeight - maximumFeatureListHeight) > 0.5
                || self.isPanelVisible != isPanelVisible
        else {
            return
        }

        objectWillChange.send()
        self.selectedTab = selectedTab
        self.contentHeight = contentHeight
        self.maximumFeatureListHeight = maximumFeatureListHeight
        self.isPanelVisible = isPanelVisible
    }

    func selectTab(_ tab: MenuBarPanelTab) {
        onTabSelection?(tab)
    }

}

struct MenuBarUnifiedPanelContent: View {
    @ObservedObject var pluginHost: PluginHost
    @ObservedObject private var runtimeLocale = PluginRuntimeLocalization.source
    @ObservedObject var model: MenuBarUnifiedPanelModel
    let onDismiss: () -> Void
    let onOpenSettings: () -> Void
    let onPresentDiskCleanConfiguration: () -> Void
    let onPresentLaunchControlConfiguration: () -> Void

    var body: some View {
        let _ = runtimeLocale.revision
        let contentBodyHeight = MenuBarPanelLayout.contentBodyHeight(
            forContentHeight: model.contentHeight
        )

        VStack(spacing: MenuBarPanelLayout.rootSpacing) {
            MenuBarPanelToolbar(
                selectedTab: model.selectedTab,
                onTabSelection: handleTabSelection,
                onOpenSettings: presentSettings,
                onQuit: {
                    NSApplication.shared.terminate(nil)
                }
            )
            .frame(height: MenuBarPanelLayout.toolbarHeight)
            .padding(.horizontal, MenuBarPanelLayout.outerPadding)

            MenuBarPanelContentSurface(contentBodyHeight: contentBodyHeight) {
                panelContent(contentBodyHeight: contentBodyHeight)
            }
        }
        .padding(.top, MenuBarPanelLayout.outerPadding)
        .frame(
            width: MenuBarPanelLayout.baseWidth,
            height: MenuBarPanelLayout.panelHeight(forContentHeight: model.contentHeight),
            alignment: .topLeading
        )
        .id(runtimeLocale.revision)
        .environment(\.locale, PluginRuntimeLocalization.locale)
        .environment(\.layoutDirection, layoutDirection)
    }

    private var layoutDirection: LayoutDirection {
        PluginRuntimeLocalization.locale.language.characterDirection == .rightToLeft
            ? .rightToLeft
            : .leftToRight
    }

    private func panelContent(contentBodyHeight: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ComponentPanelContent(
                pluginHost: pluginHost,
                contentBodyHeight: contentBodyHeight,
                onDismiss: onDismiss
            )
            .opacity(model.selectedTab == .components ? 1 : 0)
            .allowsHitTesting(model.isPanelVisible && model.selectedTab == .components)
            .accessibilityHidden(model.selectedTab != .components)

            MenuBarContent(
                pluginHost: pluginHost,
                contentBodyHeight: contentBodyHeight,
                maximumFeatureListHeight: model.maximumFeatureListHeight,
                isPanelVisible: model.isPanelVisible && model.selectedTab == .features,
                onDismiss: onDismiss,
                onOpenSettings: onOpenSettings,
                onPresentDiskCleanConfiguration: onPresentDiskCleanConfiguration,
                onPresentLaunchControlConfiguration: onPresentLaunchControlConfiguration
            )
            .opacity(model.selectedTab == .features ? 1 : 0)
            .allowsHitTesting(model.isPanelVisible && model.selectedTab == .features)
            .accessibilityHidden(model.selectedTab != .features)
        }
    }

    private func presentSettings() {
        onOpenSettings()
        onDismiss()
    }

    private func handleTabSelection(_ tab: MenuBarPanelTab) {
        guard model.selectedTab != tab else {
            return
        }

        model.selectTab(tab)
    }

}

private struct MenuBarPanelContentSurface<Content: View>: View {
    let contentBodyHeight: CGFloat
    private let content: Content

    init(contentBodyHeight: CGFloat, @ViewBuilder content: () -> Content) {
        self.contentBodyHeight = contentBodyHeight
        self.content = content()
    }

    var body: some View {
        content
            .frame(
                width: MenuBarPanelLayout.surfaceWidth,
                height: contentBodyHeight,
                alignment: .topLeading
            )
            .padding(.top, MenuBarPanelLayout.contentTopPadding)
            .padding(.horizontal, MenuBarPanelLayout.outerPadding)
            .padding(.bottom, MenuBarPanelLayout.contentBottomPadding)
            .frame(
                width: MenuBarPanelLayout.baseWidth,
                height: contentBodyHeight + MenuBarPanelLayout.contentVerticalPadding,
                alignment: .topLeading
            )
    }
}

private struct MenuBarPanelToolbar: View {
    let selectedTab: MenuBarPanelTab
    let onTabSelection: (MenuBarPanelTab) -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            MenuBarPanelTabSwitcher(
                selectedTab: selectedTab,
                onTabSelection: onTabSelection
            )

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                MenuBarPanelIconButton(
                    systemImage: "gearshape",
                    accessibilityTitle: AppL10n.settings("settings.window.title", defaultValue: "设置"),
                    action: onOpenSettings
                )

                MenuBarPanelIconButton(
                    systemImage: "power",
                    accessibilityTitle: AppL10n.settings("app.quit", defaultValue: "退出"),
                    action: onQuit
                )
            }
        }
    }
}

private struct MenuBarPanelTabSwitcher: View {
    let selectedTab: MenuBarPanelTab
    let onTabSelection: (MenuBarPanelTab) -> Void
    @FocusState private var focusedTab: MenuBarPanelTab?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MenuBarPanelTab.allCases, id: \.self) { tab in
                Button {
                    guard selectedTab != tab else {
                        return
                    }

                    onTabSelection(tab)
                } label: {
                    Image(systemName: tab.systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selectedTab == tab ? Color.primary : Color.secondary)
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($focusedTab, equals: tab)
                .help(tab.accessibilityTitle)
                .accessibilityLabel(tab.accessibilityTitle)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selectedTab == tab ? Color.primary.opacity(0.10) : Color.clear)
                }
            }
        }
        .padding(3)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        }
        .defaultFocus($focusedTab, selectedTab)
    }
}

private struct MenuBarPanelIconButton: View {
    let systemImage: String
    let accessibilityTitle: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(accessibilityTitle)
        .accessibilityLabel(accessibilityTitle)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
        }
        .onHover { isHovered = $0 }
    }
}
