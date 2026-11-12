import 'package:flutter/material.dart';
import 'storage/saathi_store.dart';
import 'ui/chat_controller.dart';
import 'ui/chat_home.dart';
import 'update_host.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SaathiApp());
}

class SaathiApp extends StatefulWidget {
  const SaathiApp({super.key, this.store, this.coreFactory, this.builder});
  final TransitionBuilder? builder;
  final SaathiStore? store;
  final CoreFactory? coreFactory;
  @override
  State<SaathiApp> createState() => _SaathiAppState();
}

class _SaathiAppState extends State<SaathiApp> {
  ChatController? controller;
  String? error;
  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final store = widget.store ?? await SaathiStore.open();
      if (!mounted) return;
      final c = ChatController(store, coreFactory: widget.coreFactory);
      setState(() => controller = c);
      await c.load();
    } catch (_) {
      if (mounted) {
        setState(() => error =
            'Secure storage could not be opened. Restart Saathi to try again.');
      }
    }
  }

  @override
  void dispose() {
    controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SaathiUpdateHost(
          child: MaterialApp(
        title: 'Saathi',
        builder: widget.builder,
        debugShowCheckedModeBanner: false,
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
                        : Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(error!))))
            : ChatHome(controller: controller!),
      ));
}
