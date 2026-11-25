import 'package:flutter/material.dart';

/// Places existing chat surfaces in a persistent, width-responsive workspace.
class AdaptiveChatShell extends StatelessWidget {
  const AdaptiveChatShell({
    super.key,
    required this.wide,
    required this.scaffoldKey,
    required this.appBar,
    required this.sidebar,
    required this.body,
    required this.settings,
    required this.showSettings,
    required this.onSettingsChanged,
    required this.onDrawerChanged,
    this.chatSettings,
    this.onChatSettingsDismiss,
  });

  final bool wide;
  final Widget? chatSettings;
  final VoidCallback? onChatSettingsDismiss;
  final GlobalKey<ScaffoldState> scaffoldKey;
  final PreferredSizeWidget appBar;
  final Widget sidebar, body, settings;
  final bool showSettings;
  final ValueChanged<bool> onSettingsChanged, onDrawerChanged;

  /// Reserve room for navigation and a usable chat pane, including larger text.
  static bool fits(BuildContext context, double width) =>
      width >= 1000 && width >= 720 * MediaQuery.textScalerOf(context).scale(1);

  @override
  Widget build(BuildContext context) {
    final conversation = Scaffold(
      key: scaffoldKey,
      appBar: appBar,
      drawer: wide ? null : sidebar,
      drawerEdgeDragWidth: 48,
      onDrawerChanged: onDrawerChanged,
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: wide ? 960 : double.infinity),
          child: body,
        ),
      ),
    );
    if (!wide) {
      return Stack(
        children: [
          ExcludeFocus(
            excluding: chatSettings != null,
            child: ExcludeSemantics(
              excluding: chatSettings != null,
              child: conversation,
            ),
          ),
          if (chatSettings != null) ...[
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onChatSettingsDismiss,
                child: const ColoredBox(color: Colors.black54),
              ),
            ),
            Positioned.fill(
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: EdgeInsets.only(
                    top: 24,
                    bottom: MediaQuery.viewInsetsOf(context).bottom,
                  ),
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Material(
                      elevation: 8,
                      clipBehavior: Clip.antiAlias,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(20),
                      ),
                      color: Theme.of(context).colorScheme.surface,
                      child: SafeArea(top: false, child: chatSettings!),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      );
    }

    final workspace = Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: conversation),
        if (chatSettings != null) ...[
          const VerticalDivider(width: 1),
          SizedBox(
            width: (340 * MediaQuery.textScalerOf(context).scale(1))
                .clamp(340, 480)
                .toDouble(),
            child: chatSettings,
          ),
        ],
      ],
    );

    return PopScope<void>(
      canPop: !showSettings,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && showSettings) onSettingsChanged(false);
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        body: SafeArea(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              NavigationRail(
                backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
                minWidth: 80,
                labelType: NavigationRailLabelType.all,
                selectedIndex: showSettings ? 1 : 0,
                onDestinationSelected: (index) => onSettingsChanged(index == 1),
                leading: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Tooltip(
                    message: 'Saathi',
                    child: Icon(Icons.spa_outlined,
                        color: Theme.of(context).colorScheme.primary),
                  ),
                ),
                destinations: const [
                  NavigationRailDestination(
                    icon: Icon(Icons.chat_bubble_outline_rounded),
                    selectedIcon: Icon(Icons.chat_bubble_rounded),
                    label: Text('Chats'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.settings_outlined),
                    selectedIcon: Icon(Icons.settings),
                    label: Text('Settings'),
                  ),
                ],
              ),
              const VerticalDivider(width: 1),
              Offstage(
                offstage: chatSettings != null && !showSettings,
                child: ExcludeFocus(
                  excluding: chatSettings != null && !showSettings,
                  child: SizedBox(width: 300, child: sidebar),
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: IndexedStack(
                  index: showSettings ? 1 : 0,
                  children: [workspace, settings],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
