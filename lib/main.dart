import 'package:flutter/material.dart';
import 'storage/saathi_store.dart';
import 'notifications/reply_notifications.dart';
import 'ui/chat_controller.dart';
import 'ui/chat_home.dart';
import 'ui/appearance.dart';
import 'update_host.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SaathiApp());
}

class SaathiApp extends StatefulWidget {
  const SaathiApp({
    super.key,
    this.store,
    this.storeOpener,
    this.coreFactory,
    this.builder,
  });
  final TransitionBuilder? builder;
  final SaathiStore? store;
  final Future<SaathiStore> Function()? storeOpener;
  final CoreFactory? coreFactory;
  @override
  State<SaathiApp> createState() => _SaathiAppState();
}

class _SaathiAppState extends State<SaathiApp> {
  ChatController? controller;
  Appearance? appearance;
  String? error;
  bool _opening = false;
  ReplyNotifications? notifications;
  final navigator = GlobalKey<NavigatorState>();

  void consumeTap() {
    final c = controller;
    if (!mounted || c == null || c.loading) return;
    notifications?.consumeTap((id) {
      if (!c.openNotificationConversation(id)) return false;
      navigator.currentState?.popUntil((route) => route.isFirst);
      return true;
    });
  }

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    if (_opening || controller != null) return;
    _opening = true;
    if (error != null) {
      setState(() => error = null);
    }
    Appearance? nextAppearance;
    ChatController? nextController;
    ReplyNotifications? nextNotifications;
    try {
      final store =
          widget.store ?? await (widget.storeOpener ?? SaathiStore.open)();
      if (!mounted) return;
      nextAppearance = Appearance(store.preferences)
        ..addListener(_appearanceChanged);
      nextController = ChatController(store, coreFactory: widget.coreFactory);
      nextNotifications = ReplyNotifications(store.preferences);
      nextController.notifications = nextNotifications;
      nextController.onReplyReceived = (id) {
        nextNotifications!.replyReceived(id);
      };
      nextNotifications.onResume = consumeTap;
      appearance = nextAppearance;
      notifications = nextNotifications;
      setState(() {
        controller = nextController;
        error = null;
      });
      await nextController.load();
      if (mounted) consumeTap();
    } catch (_) {
      if (identical(appearance, nextAppearance)) appearance = null;
      if (identical(notifications, nextNotifications)) notifications = null;
      if (identical(controller, nextController)) controller = null;
      nextAppearance?.removeListener(_appearanceChanged);
      nextAppearance?.dispose();
      nextNotifications?.dispose();
      nextController?.dispose();
      if (mounted) {
        setState(() => error =
            'Secure storage could not be opened. Check storage access and try again.');
      }
    } finally {
      _opening = false;
    }
  }

  @override
  void dispose() {
    appearance?.removeListener(_appearanceChanged);
    appearance?.dispose();
    notifications?.dispose();
    controller?.dispose();
    super.dispose();
  }

  void _appearanceChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => AppearanceScope(
      notifier: appearance,
      child: SaathiUpdateHost(
          child: MaterialApp(
        navigatorKey: navigator,
        title: 'Saathi',
        builder: widget.builder,
        debugShowCheckedModeBanner: false,
        themeMode: appearance?.mode ?? ThemeMode.system,
        darkTheme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xFF3E6559),
                brightness: Brightness.dark)),
        theme: ThemeData(
            useMaterial3: true,
            colorScheme:
                ColorScheme.fromSeed(seedColor: const Color(0xFF3E6559)),
            scaffoldBackgroundColor: const Color(0xFFFAFAF8),
            appBarTheme: const AppBarTheme(
                backgroundColor: Color(0xFFFAFAF8),
                surfaceTintColor: Colors.transparent),
            textTheme: ThemeData.light().textTheme.apply(
                bodyColor: const Color(0xFF252B29),
                displayColor: const Color(0xFF252B29))),
        home: controller == null
            ? Scaffold(
                body: Center(
                    child: error == null
                        ? const CircularProgressIndicator()
                        : SingleChildScrollView(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(error!, textAlign: TextAlign.center),
                                  const SizedBox(height: 16),
                                  FilledButton(
                                      onPressed: _open,
                                      child: const Text('Try again'))
                                ]))))
            : ChatHome(controller: controller!),
      )));
}
