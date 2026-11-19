import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  const UpdateSettingsButton({super.key, this.asTile = false});
  final bool asTile;
  @override
  Widget build(BuildContext context) {
    void open() =>
        Navigator.of(context).push(MaterialPageRoute<void>(builder: (context) {
          final scope =
              context.dependOnInheritedWidgetOfExactType<_UpdateScope>();
          return SaathiUpdatesPage(
              controller: scope?.controller, initializationError: scope?.error);
        }));
    if (asTile) {
      return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.system_update_alt),
          title: const Text('App updates'),
          subtitle: const Text('Check for updates and read what’s new'),
          trailing: const Icon(Icons.chevron_right),
          onTap: open);
    }
    return IconButton(
        tooltip: 'App updates',
        icon: const Icon(Icons.system_update_alt),
        onPressed: open);
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
                    ? 'Saathi will download the update, then Android will ask before installing it. Your chats won’t be shared.'
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
              ? 'Use Google Play to check for updates for this app.'
              : 'Updates are not configured for this app.';
          return Scaffold(
              appBar: AppBar(title: const Text('App updates')),
              body: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                            'Current version: ${updates.service.installed.name}',
                            style: Theme.of(context).textTheme.titleLarge),
                        const SizedBox(height: 16),
                        Text(config.enabled
                            ? _statusText(updates)
                            : disabledReason),
                        const SizedBox(height: 20),
                        OutlinedButton.icon(
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
                        if (updates.error != null) ...[
                          const SizedBox(height: 16),
                          Text(updates.error!,
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.error))
                        ],
                        if (offer != null) ...[
                          const SizedBox(height: 24),
                          Text('Available: ${offer.version.name}',
                              style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 8),
                          Text(updates.supportsAndroidInstall
                              ? 'Read the changes below before installing. Android will ask for your approval.'
                              : 'Desktop installation is manual. Open the release page in your browser to choose a download.'),
                          const SizedBox(height: 16),
                          FilledButton(
                              onPressed: working
                                  ? null
                                  : () => _confirm(context, updates),
                              child: Text(updates.supportsAndroidInstall
                                  ? 'Install update'
                                  : 'Open releases')),
                        ],
                        if (updates.status == UpdateStatus.handedOff) ...[
                          const SizedBox(height: 16),
                          Text(updates.supportsAndroidInstall
                              ? 'Follow Android’s prompts to finish installing.'
                              : 'The release page opened. No update was installed by Saathi.')
                        ],
                        const SizedBox(height: 24),
                        Text("What's new",
                            style: Theme.of(context).textTheme.titleLarge),
                        _ReleaseHistory(remote: updates.service.releaseNotes),
                      ])));
        });
  }
}

String _statusText(SaathiUpdateController updates) => switch (updates.status) {
      UpdateStatus.checking => 'Checking for updates…',
      UpdateStatus.upToDate => 'You’re up to date.',
      UpdateStatus.available => 'An update is ready.',
      UpdateStatus.downloading => 'Downloading your update…',
      UpdateStatus.error => 'Could not finish the update. Please try again.',
      UpdateStatus.handedOff => 'Finish the update outside Saathi.',
      _ => 'Saathi checks for updates automatically.',
    };

class _ReleaseHistory extends StatefulWidget {
  const _ReleaseHistory({required this.remote});
  final List<ReleaseNotes> remote;
  @override
  State<_ReleaseHistory> createState() => _ReleaseHistoryState();
}

class _ReleaseHistoryState extends State<_ReleaseHistory> {
  final _bundled = rootBundle
      .loadString('assets/changelog.json', cache: false)
      .then(ReleaseNotes.fromChangelog)
      .catchError((Object _) => <ReleaseNotes>[]);
  @override
  Widget build(BuildContext context) => FutureBuilder<List<ReleaseNotes>>(
      future: _bundled,
      builder: (context, snapshot) {
        final history =
            ReleaseNotes.merge(snapshot.data ?? const [], widget.remote);
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (history.isEmpty)
            Text(snapshot.connectionState == ConnectionState.waiting
                ? 'Loading changes…'
                : 'Change notes are not available.'),
          for (final release in history) ...[
            const SizedBox(height: 20),
            Text(release.version,
                style: Theme.of(context).textTheme.titleMedium),
            if (release.changes.isEmpty)
              const Text('Change notes are not available for this version.'),
            for (final change in release.changes)
              Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('• $change')),
          ],
        ]);
      });
}
