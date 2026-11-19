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
  });

  final bool wide;
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
    if (!wide) return conversation;

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
                backgroundColor: const Color(0xFFE9EDE7),
                minWidth: 80,
                labelType: NavigationRailLabelType.all,
                selectedIndex: showSettings ? 1 : 0,
                onDestinationSelected: (index) => onSettingsChanged(index == 1),
                leading: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Tooltip(
                    message: 'Saathi',
                    child: Icon(Icons.spa_outlined, color: Color(0xFF3E6559)),
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
              SizedBox(width: 300, child: sidebar),
              const VerticalDivider(width: 1),
              Expanded(
                child: IndexedStack(
                  index: showSettings ? 1 : 0,
                  children: [conversation, settings],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
