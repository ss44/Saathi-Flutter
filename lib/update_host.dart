import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'updates/saathi_updates.dart';

/// One updater for the whole app, including routes pushed after the home screen.
class SaathiUpdateHost extends StatefulWidget {
  const SaathiUpdateHost({super.key, required this.child, this.controller});
  final Widget child;
  final SaathiUpdateController? controller;

  @override
  State<SaathiUpdateHost> createState() => _SaathiUpdateHostState();
}

class _SaathiUpdateHostState extends State<SaathiUpdateHost> {
  SaathiUpdateController? controller;
  String? initializationError;

  @override
  void initState() {
    super.initState();
    controller = widget.controller;
    if (controller != null) {
      controller!.start();
    } else {
      _initialize();
    }
  }

  Future<void> _initialize() async {
    try {
      final package = await PackageInfo.fromPlatform();
      final installed =
          UpdateVersion.parse(package.version, int.parse(package.buildNumber));
      if (!mounted) return;
      final update = SaathiUpdateController(
          service: SaathiUpdateService(
              config: UpdateConfig.fromEnvironment(), installed: installed));
      setState(() => controller = update);
      update.start();
    } catch (_) {
      if (mounted) {
        setState(() => initializationError =
            'Could not read the installed app version. Update checks are disabled.');
      }
    }
  }

  @override
  void dispose() {
    if (widget.controller == null) controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _UpdateScope(
      controller: controller, error: initializationError, child: widget.child);
}

class _UpdateScope extends InheritedWidget {
  const _UpdateScope(
      {required this.controller, required this.error, required super.child});
  final SaathiUpdateController? controller;
  final String? error;
  @override
  bool updateShouldNotify(_UpdateScope oldWidget) =>
      oldWidget.controller != controller || oldWidget.error != error;
}

class UpdateSettingsButton extends StatelessWidget {
  const UpdateSettingsButton({super.key});
  @override
  Widget build(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_UpdateScope>();
    return IconButton(
        tooltip: 'App updates',
        icon: const Icon(Icons.system_update_alt),
        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => SaathiUpdatesPage(
                controller: scope?.controller,
                initializationError: scope?.error))));
  }
}

/// Visible when automatic checking discovers an eligible newer release.
class UpdateAvailabilityBanner extends StatelessWidget {
  const UpdateAvailabilityBanner({super.key});
  @override
  Widget build(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_UpdateScope>();
    final controller = scope?.controller;
    if (controller == null) return const SizedBox.shrink();
    return ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          if (controller.offer == null ||
              ![UpdateStatus.available, UpdateStatus.downloading]
                  .contains(controller.status)) {
            return const SizedBox.shrink();
          }
          return MaterialBanner(
              content: Text(
                  'Saathi ${controller.offer!.version.name} is available.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                            builder: (_) =>
                                SaathiUpdatesPage(controller: controller))),
                    child: const Text('Review update'))
              ]);
        });
  }
}

class SaathiUpdatesPage extends StatelessWidget {
  const SaathiUpdatesPage(
      {super.key, this.controller, this.initializationError});
  final SaathiUpdateController? controller;
  final String? initializationError;

  Future<void> _confirm(
      BuildContext context, SaathiUpdateController updates) async {
    final android = updates.supportsAndroidInstall;
    final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: Text(android
                    ? 'Download this update?'
                    : 'Open the release page?'),
                content: Text(android
                    ? 'Saathi will download and verify the APK, then ask Android to install it. Android may first ask you to allow updates from Saathi. Your conversations are not uploaded.'
                    : 'This opens GitHub in your browser. Desktop installation is manual; Saathi will not replace or restart itself.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(android ? 'Download' : 'Open releases'))
                ]));
    if (approved != true) return;
    if (android) {
      await updates.installAndroid(userConsented: true);
    } else {
      await updates.openReleasePage(userConsented: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final updates = controller;
    if (updates == null) {
      return Scaffold(
          appBar: AppBar(title: const Text('App updates')),
          body: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(initializationError ??
                  'Reading the installed app version…')));
    }
    return ListenableBuilder(
        listenable: updates,
        builder: (context, _) {
          final config = updates.service.config;
          final working = [UpdateStatus.checking, UpdateStatus.downloading]
              .contains(updates.status);
          final offer = updates.offer;
          final disabledReason = config.distribution == 'play'
              ? 'This is a Play distribution. GitHub self-updates are disabled; Play updates are not integrated yet.'
              : 'Automatic updates are not configured for this build. A release repository and a production-signed release are required.';
          return Scaffold(
              appBar: AppBar(title: const Text('App updates')),
              body: ListView(padding: const EdgeInsets.all(24), children: [
                Text(
                    'Saathi ${updates.service.installed.name} · build ${updates.service.installed.build}',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 16),
                Text(config.enabled
                    ? 'Automatic checks run at launch and when you return to the app, at most once every six hours.'
                    : disabledReason),
                if (config.enabled) ...[
                  const SizedBox(height: 8),
                  Text('${config.owner}/${config.repo} · ${config.channel}'),
                ],
                const SizedBox(height: 20),
                FilledButton.icon(
                    onPressed: !config.enabled || working
                        ? null
                        : () => updates.check(force: true),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Check for updates')),
                if (working) ...[
                  const SizedBox(height: 16),
                  LinearProgressIndicator(
                      value: updates.status == UpdateStatus.downloading
                          ? updates.progress
                          : null)
                ],
                if (updates.status == UpdateStatus.upToDate) ...[
                  const SizedBox(height: 16),
                  const Text('No newer eligible release was found.')
                ],
                if (updates.error != null) ...[
                  const SizedBox(height: 16),
                  Text(updates.error!,
                      style:
                          TextStyle(color: Theme.of(context).colorScheme.error))
                ],
                if (offer != null) ...[
                  const SizedBox(height: 24),
                  Text(
                      'Available: ${offer.version.name} · build ${offer.version.build}',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(updates.supportsAndroidInstall
                      ? 'The download is checked for size and SHA-256. Android also verifies app identity and signing before accepting an upgrade.'
                      : 'This release feed currently contains Android APKs. Desktop automatic installation is not implemented.'),
                  const SizedBox(height: 16),
                  OutlinedButton(
                      onPressed:
                          working ? null : () => _confirm(context, updates),
                      child: Text(updates.supportsAndroidInstall
                          ? 'Install update'
                          : 'Open releases')),
                ],
                if (updates.status == UpdateStatus.handedOff) ...[
                  const SizedBox(height: 16),
                  Text(updates.supportsAndroidInstall
                      ? 'Android installer opened. Installation still requires your approval.'
                      : 'The release page opened. No update was installed by Saathi.')
                ],
              ]));
        });
  }
}
