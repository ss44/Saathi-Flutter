import 'dart:async';
import 'package:flutter/material.dart';
import 'canonical_connection.dart';
import '../update_host.dart';
import '../notifications/settings.dart';
import '../core/saathi_core.dart';
import 'chat_controller.dart';
import 'remote_sessions.dart';
import 'optimizer_settings.dart';
import 'appearance.dart';

const providerLabels = {
  'openai': 'OpenAI-compatible',
  'anthropic': 'Anthropic',
  'gemini': 'Gemini',
  'hermes': 'Hermes',
  'hermesGateway': 'Hermes Desktop / CLI',
  'openclaw': 'OpenClaw'
};

/// Documented default API roots for supported connection types.
const defaultProviderBaseUrls = {
  'openai': 'https://api.openai.com',
  'anthropic': 'https://api.anthropic.com',
  'gemini': 'https://generativelanguage.googleapis.com',
  'hermes': 'http://127.0.0.1:8642',
};

class ConnectionsPage extends StatefulWidget {
  const ConnectionsPage(
      {super.key, required this.controller, this.embedded = false});
  final ChatController controller;

  /// Embedded desktop settings keep navigation in the workspace rail.
  final bool embedded;
  @override
  State<ConnectionsPage> createState() => _ConnectionsPageState();
}

class _ConnectionsPageState extends State<ConnectionsPage> {
  ChatController get controller => widget.controller;
  late final chat = controller.current;
  String? opened;
  Future<void> action(Map<String, dynamic> c, String action) async {
    setState(() => opened = null);
    if (action == 'Edit' && c['type'] == 'hermesGateway') {
      await Navigator.push(
          context,
          CanonicalConnectionRoute<void>(
              builder: (_) => CanonicalConnectionPage(
                  controller: controller, connection: c)));
      return;
    }
    if (action == 'Edit') {
      await Navigator.push(
          context,
          MaterialPageRoute<void>(
              builder: (_) =>
                  AddConnectionPage(controller: controller, connection: c)));
      return;
    }
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: Text('Delete “${c['name']}”?'),
                content: const Text(
                    'Remove this connection and its secure key? Local conversations are kept read-only. Nothing on your server is deleted.'),
                actions: [
                  TextButton(
                      autofocus: true,
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel')),
                  TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Delete'))
                ]));
    if (confirmed != true || !mounted) return;
    try {
      await controller.deleteConnection(c['id']);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Could not remove connection. Storage may need recovery; nothing was removed from this screen.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(
          automaticallyImplyLeading: !widget.embedded,
          title: const Text('Settings')),
      body: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              // Keep every settings section in keyboard focus traversal.
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _SettingsHeading('Connections'),
                    const SizedBox(height: 12),
                    const Text(
                        'Keys are held in platform secure storage. Chat history is stored on this device. Existing conversations stay bound to their original connection.'),
                    if (controller.organization.saving ||
                        controller.organization.hasUnsavedChanges)
                      const Text(
                          'Save or recover conversation details in Chats before changing connections.'),
                    const SizedBox(height: 20),
                    for (final c in controller.connections)
                      GestureDetector(
                          onHorizontalDragUpdate: (d) {
                            if (d.delta.dx < -2) {
                              setState(() => opened = c['id']);
                            }
                            if (d.delta.dx > 2) setState(() => opened = null);
                          },
                          child: ClipRect(
                              child: Stack(
                                  alignment: Alignment.centerRight,
                                  children: [
                                if (opened == c['id'])
                                  SizedBox(
                                      width: 160,
                                      child: Row(children: [
                                        for (final a in ['Edit', 'Delete'])
                                          Expanded(
                                              child: IconButton(
                                                  tooltip: a,
                                                  constraints:
                                                      const BoxConstraints(
                                                          minWidth: 48,
                                                          minHeight: 48),
                                                  onPressed: controller
                                                          .canChangeConnections
                                                      ? () => action(c, a)
                                                      : null,
                                                  icon: Icon(
                                                      a == 'Edit'
                                                          ? Icons.edit_outlined
                                                          : Icons
                                                              .delete_outline,
                                                      semanticLabel: a)))
                                      ])),
                                TweenAnimationBuilder<double>(
                                    key: ValueKey('slide-${c['id']}'),
                                    duration: const Duration(milliseconds: 180),
                                    tween: Tween(
                                        begin: 0,
                                        end: opened == c['id'] ? -160 : 0),
                                    builder: (_, x, child) =>
                                        Transform.translate(
                                            offset: Offset(x, 0), child: child),
                                    child: Material(
                                        color: Theme.of(context)
                                            .scaffoldBackgroundColor,
                                        child: ListTile(
                                            contentPadding: EdgeInsets.zero,
                                            leading:
                                                const Icon(Icons.dns_outlined),
                                            title: Text(c['name']),
                                            trailing: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  if (c['type'] == 'hermes')
                                                    IconButton(
                                                        tooltip:
                                                            'Browse remote sessions',
                                                        icon: const Icon(Icons
                                                            .cloud_outlined),
                                                        onPressed: () => Navigator.push(
                                                            context,
                                                            MaterialPageRoute<
                                                                    void>(
                                                                builder: (_) => RemoteSessionsPage(
                                                                    controller:
                                                                        controller,
                                                                    connection:
                                                                        c)))),
                                                  PopupMenuButton<String>(
                                                      tooltip:
                                                          'Connection actions',
                                                      enabled: controller
                                                          .canChangeConnections,
                                                      onSelected: (a) =>
                                                          action(c, a),
                                                      itemBuilder: (_) => [
                                                            for (final a in [
                                                              'Edit',
                                                              'Delete'
                                                            ])
                                                              PopupMenuItem(
                                                                  value: a,
                                                                  child:
                                                                      Text(a))
                                                          ]),
                                                ]),
                                            subtitle: Text(
                                                '${providerLabels[c['type']]} · ${c['url']}')))),
                              ]))),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                        onPressed: !controller.canChangeConnections
                            ? null
                            : () => Navigator.push(
                                context,
                                MaterialPageRoute<void>(
                                    builder: (_) => AddConnectionPage(
                                        controller: controller))),
                        icon: const Icon(Icons.add),
                        label: const Text('Add connection')),
                    const SizedBox(height: 24),
                    const _SettingsHeading('Application'),
                    const Text(
                        'Defaults and preferences for Saathi on this device.'),
                    const AppearanceSetting(),
                    OptimizerSettingsButton(
                        controller: controller, asTile: true),
                    if (controller.notifications != null)
                      NotificationSettingsButton(
                          notifications: controller.notifications!,
                          asTile: true),
                    const UpdateSettingsButton(asTile: true),
                    if (chat != null &&
                        identical(chat, controller.current)) ...[
                      const SizedBox(height: 24),
                      const _SettingsHeading('Current conversation'),
                      Text(controller.displayTitle(chat!)),
                      const Text(
                          'Only this conversation. Its response model, connection and instructions are unchanged.'),
                      OptimizerSettingsButton(
                          controller: controller, chat: chat, asTile: true),
                    ],
                  ]))));
}

class _SettingsHeading extends StatelessWidget {
  const _SettingsHeading(this.title);
  final String title;
  @override
  Widget build(BuildContext context) => Semantics(
      header: true,
      child: Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(title, style: Theme.of(context).textTheme.titleLarge)));
}

class AddConnectionPage extends StatefulWidget {
  const AddConnectionPage(
      {super.key, required this.controller, this.connection});
  final ChatController controller;
  final Map<String, dynamic>? connection;
  @override
  State<AddConnectionPage> createState() => _AddConnectionPageState();
}

class _AddConnectionPageState extends State<AddConnectionPage>
    with WidgetsBindingObserver {
  final form = GlobalKey<FormState>();
  final name = TextEditingController(),
      url = TextEditingController(),
      keyInput = TextEditingController();
  String type = 'openai';
  String? error, testStatus;
  bool saving = false,
      testing = false,
      showKey = false,
      keyReady = false,
      clearKey = false;
  String? initialKey;
  SaathiCore? _activeTestCore;
  int _testGeneration = 0;

  void _invalidateTest() {
    _testGeneration++;
    _activeTestCore?.close();
    _activeTestCore = null;
    testing = false;
    testStatus = null;
  }

  String? _validateUrl(String? v) {
    final uri = Uri.tryParse((v ?? '').trim());
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return 'Use an http(s) URL without credentials or query';
    }
    if (uri.scheme == 'http' &&
        !['localhost', '127.0.0.1', '::1', '[::1]'].contains(uri.host)) {
      return 'Use HTTPS for remote servers. HTTP is only supported on loopback.';
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final c = widget.connection;
    if (c == null) {
      url.text = defaultProviderBaseUrls[type] ?? '';
      keyReady = true;
      return;
    }
    name.text = c['name'];
    url.text = c['url'];
    type = c['type'];
    loadKey();
  }

  Future<void> loadKey() async {
    try {
      final value = await widget.controller.store
          .readConnectionSecret(widget.connection!['id']);
      if (!mounted) return;
      setState(() {
        initialKey = value ?? '';
        keyInput.text = initialKey!;
        keyReady = true;
      });
    } catch (_) {
      if (mounted) {
        setState(() => error =
            'Secure key could not be read. Editing is disabled; cancel and try again.');
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && mounted) {
      setState(() => showKey = false);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (ModalRoute.isCurrentOf(context) != true) showKey = false;
  }

  @override
  void deactivate() {
    showKey = false;
    super.deactivate();
  }

  @override
  void dispose() {
    _invalidateTest();
    WidgetsBinding.instance.removeObserver(this);
    name.dispose();
    url.dispose();
    keyInput.dispose();
    super.dispose();
  }

  Future<void> testConnection() async {
    if (testing ||
        saving ||
        !keyReady ||
        type == 'openclaw' ||
        !ProviderType.values.asNameMap().containsKey(type)) {
      return;
    }
    final urlError = _validateUrl(url.text);
    if (urlError != null) {
      setState(() {
        error = urlError;
        testStatus = null;
      });
      return;
    }
    final generation = ++_testGeneration;
    _activeTestCore?.close();
    final core = widget.controller.coreFactory();
    _activeTestCore = core;
    setState(() {
      testing = true;
      error = null;
      testStatus = null;
    });
    try {
      final normalizedKey = keyInput.text.trim();
      final token = clearKey
          ? ''
          : (widget.connection != null &&
                  (normalizedKey.isEmpty ||
                      normalizedKey == initialKey?.trim()))
              ? (initialKey ?? '')
              : normalizedKey;
      core.addProvider(ProviderConfig(
        id: 'connection-test',
        name: name.text.trim().isEmpty ? 'Test' : name.text.trim(),
        type: ProviderType.values.byName(type),
        apiKey: token,
        baseUrl: url.text.trim(),
      ));
      final found = await core.discoverModels(
        'connection-test',
        isCurrent: () => mounted && generation == _testGeneration,
      );
      if (!mounted || generation != _testGeneration) return;
      setState(() {
        testStatus = found.isEmpty
            ? 'Connection verified. No models returned.'
            : 'Connection verified · ${found.length} ${found.length == 1 ? 'model' : 'models'} available.';
      });
    } on ProviderException catch (e) {
      if (mounted && generation == _testGeneration) {
        setState(() => error = e.message);
      }
    } catch (_) {
      if (mounted && generation == _testGeneration) {
        setState(() => error =
            'Could not reach this server. Check the URL and credentials.');
      }
    } finally {
      core.close();
      if (identical(_activeTestCore, core)) _activeTestCore = null;
      if (mounted && generation == _testGeneration) {
        setState(() => testing = false);
      }
    }
  }

  Future<void> save() async {
    if (!widget.controller.canChangeConnections) return;
    if (!form.currentState!.validate()) return;
    _invalidateTest();
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final values = <String, dynamic>{
        'id': DateTime.now().microsecondsSinceEpoch.toString(),
        'name': name.text.trim(),
        'url': url.text.trim(),
        'type': type,
      };
      if (widget.connection == null) {
        await widget.controller.addConnection(values, keyInput.text.trim());
      } else {
        final normalizedKey = keyInput.text.trim();
        await widget.controller.updateConnection(
            widget.connection!['id'], values,
            apiKey: clearKey
                ? ''
                : normalizedKey.isEmpty || normalizedKey == initialKey?.trim()
                    ? null
                    : normalizedKey);
      }
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          saving = false;
          error = 'Could not save securely. No key was stored in preferences.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(
          title: Text(widget.connection == null
              ? 'Add connection'
              : 'Edit connection')),
      body: Form(
          key: form,
          child: ListView(padding: const EdgeInsets.all(20), children: [
            TextFormField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Connection name'),
                validator: (v) => v!.trim().isEmpty ? 'Enter a name' : null),
            const SizedBox(height: 18),
            DropdownButtonFormField<String>(
                initialValue: type,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Provider type'),
                items: providerLabels.entries
                    .where((entry) =>
                        entry.key != 'hermesGateway' &&
                        (entry.key != 'openclaw' ||
                            widget.connection?['type'] == 'openclaw'))
                    .map((e) =>
                        DropdownMenuItem(value: e.key, child: Text(e.value)))
                    .toList(),
                onChanged: (v) => setState(() {
                      if (v == null) return;
                      _invalidateTest();
                      final currentUrl = url.text.trim();
                      if (widget.connection == null &&
                          (currentUrl.isEmpty ||
                              defaultProviderBaseUrls.values
                                  .contains(currentUrl))) {
                        url.text = defaultProviderBaseUrls[v] ?? '';
                      }
                      type = v;
                      error = null;
                    })),
            const SizedBox(height: 18),
            TextFormField(
                controller: url,
                autocorrect: false,
                keyboardType: TextInputType.url,
                onChanged: (_) {
                  if (testing || testStatus != null) {
                    setState(_invalidateTest);
                  }
                },
                decoration: InputDecoration(
                    labelText: 'API base URL',
                    hintText: defaultProviderBaseUrls[type] ??
                        'https://api.example.com'),
                validator: _validateUrl),
            const SizedBox(height: 18),
            if (widget.connection != null)
              const Padding(
                  padding: EdgeInsets.only(bottom: 18),
                  child: Text(
                      'Changing provider or API URL creates a new connection. Existing conversations remain read-only on the old destination and are never uploaded to the new destination.')),
            TextFormField(
                key: const Key('connection-key'),
                controller: keyInput,
                enabled: keyReady && !saving,
                obscureText: !showKey,
                enableIMEPersonalizedLearning: false,
                autocorrect: false,
                enableSuggestions: false,
                onChanged: (_) {
                  clearKey = false;
                  if (testing || testStatus != null) {
                    setState(_invalidateTest);
                  }
                },
                decoration: InputDecoration(
                    suffixIcon: IconButton(
                        tooltip: showKey ? 'Hide API key' : 'Show API key',
                        onPressed: keyReady
                            ? () => setState(() => showKey = !showKey)
                            : null,
                        icon: Icon(
                            showKey ? Icons.visibility_off : Icons.visibility)),
                    labelText: 'API key / token',
                    helperText:
                        'Optional for a local server. Never saved in chat history.')),
            if (widget.connection != null)
              TextButton(
                  onPressed: keyReady && !saving
                      ? () => setState(() {
                            _invalidateTest();
                            clearKey = true;
                            keyInput.clear();
                            showKey = false;
                          })
                      : null,
                  child: Text(clearKey
                      ? 'Key will be removed on Save'
                      : 'Clear stored key')),
            const SizedBox(height: 20),
            const Text(
                'Use HTTPS for remote servers. HTTP is only supported on loopback. Hermes support depends on the server protocol; unsupported operations are reported, not simulated.'),
            if (!widget.controller.canChangeConnections)
              Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                      'Resolve unsaved changes or storage errors before saving connections.',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error))),
            if (testStatus != null)
              Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(testStatus!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.primary))),
            if (error != null)
              Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error))),
            const SizedBox(height: 20),
            if (type != 'openclaw') ...[
              OutlinedButton.icon(
                  onPressed:
                      saving || testing || !keyReady ? null : testConnection,
                  icon: const Icon(Icons.network_check),
                  label: Text(testing ? 'Testing…' : 'Test connection')),
              const SizedBox(height: 12),
            ],
            FilledButton(
                onPressed: saving ||
                        !keyReady ||
                        !widget.controller.canChangeConnections
                    ? null
                    : save,
                child: Text(saving ? 'Saving securely…' : 'Save connection')),
            TextButton(
                onPressed: saving
                    ? null
                    : () {
                        setState(() => showKey = false);
                        Navigator.pop(context);
                      },
                child: const Text('Cancel')),
          ])));
}

class NewChatPage extends StatefulWidget {
  const NewChatPage(
      {super.key, required this.controller, this.autoDiscover = false});
  final ChatController controller;

  /// When true, automatically discovers models for the selected connection on
  /// page entry and connection changes.
  final bool autoDiscover;
  @override
  State<NewChatPage> createState() => _NewChatPageState();
}

class _NewChatPageState extends State<NewChatPage> {
  Map<String, dynamic>? connection;
  List<ModelInfo> models = [];
  ModelInfo? selectedModel;
  String? selectedPersonaId;
  String? _preferredModel;
  String? _preferredUpstreamProvider;
  bool _userEditedModel = false;
  int catalogRevision = 0;
  int? catalogGeneration;
  Completer<void>? _discoverCancel;

  void _cancelDiscovery() {
    final cancel = _discoverCancel;
    _discoverCancel = null;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
  }

  bool get catalogCurrent =>
      widget.controller.canDiscoverModels &&
      catalogGeneration == widget.controller.catalogGeneration &&
      connection != null &&
      widget.controller.isCurrentConnection(connection!);

  bool get _isDirectConnection =>
      const {'openai', 'anthropic', 'gemini'}.contains(connection?['type']);

  String? get _effectivePersonaId => selectedPersonaId != null &&
          widget.controller.organization.personas
              .any((p) => p.id == selectedPersonaId)
      ? selectedPersonaId
      : null;

  void clearCatalog() {
    models = [];
    selectedModel = null;
    model.clear();
  }

  void syncController() {
    if (!mounted) return;
    final revoked = !catalogCurrent;
    if (revoked) catalogRevision++;
    final revision = catalogRevision;
    // Revoke synchronously, but defer all notifier/UI writes: ChatHome can
    // revoke during unmount while Flutter has locked the widget tree.
    Future.microtask(() {
      if (!mounted) return;
      setState(() {
        if (revoked && revision == catalogRevision) {
          discovering = false;
          clearCatalog();
          final connections = widget.controller.connections;
          if (connection != null &&
              !widget.controller.isCurrentConnection(connection!)) {
            connection = connections
                    .where((c) => c['id'] == connection!['id'])
                    .firstOrNull ??
                connections
                    .where((c) => c['type'] != 'hermesGateway')
                    .firstOrNull;
          }
        }
      });
    });
  }

  final model = TextEditingController(), prompt = TextEditingController();
  String? error;
  bool discovering = false, starting = false;
  @override
  void initState() {
    super.initState();
    final eligible = widget.controller.connections
        .where((c) => c['type'] != 'hermesGateway')
        .toList();
    final candidates = [
      if (widget.controller.current != null) widget.controller.current!,
      ...widget.controller.orderedSessions(),
    ];
    ChatSession? prior;
    for (final session in candidates) {
      final match = eligible
          .where(
              (c) => c['id'] == session.connectionId && c['type'] != 'openclaw')
          .firstOrNull;
      if (match != null) {
        connection = match;
        prior = session;
        break;
      }
    }
    connection ??= eligible.where((c) => c['type'] != 'openclaw').firstOrNull ??
        eligible.firstOrNull;
    if (prior != null && connection != null) {
      final priorModel = widget.controller.replyModel(prior).trim();
      if (priorModel.isNotEmpty) {
        _preferredModel = priorModel;
        _preferredUpstreamProvider = prior.upstreamProvider;
        if (connection!['type'] != 'hermes') {
          model.text = priorModel;
        }
      }
    }
    catalogGeneration = widget.controller.catalogGeneration;
    widget.controller.addListener(syncController);
    if (widget.autoDiscover &&
        connection != null &&
        connection!['type'] != 'openclaw') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !discovering) unawaited(discover());
      });
    }
  }

  @override
  void dispose() {
    _cancelDiscovery();
    widget.controller.removeListener(syncController);
    catalogRevision++;
    model.dispose();
    prompt.dispose();
    super.dispose();
  }

  Future<void> discover() async {
    if (!widget.controller.canDiscoverModels ||
        connection == null ||
        connection?['type'] == 'openclaw') {
      return;
    }
    _cancelDiscovery();
    final cancel = Completer<void>();
    _discoverCancel = cancel;
    final target = connection!;
    catalogGeneration = widget.controller.catalogGeneration;
    final revision = ++catalogRevision;
    bool valid() =>
        mounted &&
        revision == catalogRevision &&
        catalogCurrent &&
        identical(connection, target) &&
        widget.controller.isCurrentConnection(target);
    setState(() {
      discovering = true;
      models = [];
      selectedModel = null;
      if (target['type'] == 'hermes') model.clear();
      error = null;
    });
    try {
      final result = await widget.controller.discover(
        target,
        isCurrent: valid,
        cancelTrigger: cancel.future,
      );
      if (valid()) {
        setState(() {
          models = result;
          if (result.isEmpty) {
            error = target['type'] == 'hermes'
                ? 'No configured models returned. Add a provider on the Hermes server, then try again.'
                : 'No models returned. Enter a model ID manually.';
          } else if (_preferredModel != null && !_userEditedModel) {
            final matches = result
                .where((m) =>
                    m.name == _preferredModel &&
                    (target['type'] != 'hermes' ||
                        m.upstreamProvider == _preferredUpstreamProvider))
                .toList();
            if (matches.length == 1 ||
                (target['type'] != 'hermes' && matches.isNotEmpty)) {
              selectedModel = matches.first;
              model.text = matches.first.name;
            }
          }
        });
      }
    } on ProviderException catch (e) {
      if (valid()) setState(() => error = e.message);
    } catch (_) {
      if (valid()) {
        setState(() => error = target['type'] == 'hermes'
            ? 'Could not load models. Check the original Hermes server and API key, then try again.'
            : 'Discovery failed. Check the URL and credentials, or enter a model ID.');
      }
    } finally {
      // Cleanup belongs to the request, not its revocable result authority.
      // A stale finisher must never reset a newer request's loading state.
      if (mounted && revision == catalogRevision) {
        setState(() {
          discovering = false;
          if (!valid()) clearCatalog();
        });
      }
    }
  }

  Future<void> start() async {
    if (connection?['type'] == 'hermes' && !catalogCurrent) return;
    setState(() {
      starting = true;
      error = null;
    });
    try {
      final effectivePersona = _isDirectConnection ? _effectivePersonaId : null;
      await widget.controller.newSession(
        connection!,
        model.text.trim(),
        effectivePersona == null ? prompt.text.trim() : '',
        upstreamProvider: selectedModel?.upstreamProvider,
        personaId: effectivePersona,
      );
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          starting = false;
          error = 'Could not save this conversation.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('New conversation')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        DropdownButtonFormField<String>(
            key: ValueKey(connection),
            initialValue: connection?['id'],
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Connection'),
            items: widget.controller.connections
                .where((c) => c['type'] != 'hermesGateway')
                .map((c) => DropdownMenuItem<String>(
                    value: c['id'], child: Text(c['name'])))
                .toList(),
            onChanged: discovering
                ? null
                : (id) {
                    setState(() {
                      connection = widget.controller.connections
                          .firstWhere((c) => c['id'] == id);
                      models = [];
                      selectedModel = null;
                      selectedPersonaId = null;
                      _preferredModel = null;
                      _preferredUpstreamProvider = null;
                      _userEditedModel = false;
                      catalogRevision++;
                      model.clear();
                      error = null;
                    });
                    if (widget.autoDiscover &&
                        connection != null &&
                        connection!['type'] != 'openclaw') {
                      unawaited(discover());
                    }
                  }),
        if (connection?['type'] == 'openclaw')
          const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text(
                  'OpenClaw requires its native gateway. This build cannot discover models or start a conversation on that protocol.')),
        if (connection?['type'] == 'hermes')
          const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text(
                  'This starts a new app-owned conversation. Existing server sessions appear in the sidebar; for Desktop / CLI sessions, use Hermes Desktop / CLI.')),
        const SizedBox(height: 16),
        OutlinedButton.icon(
            onPressed: connection == null ||
                    !widget.controller.canDiscoverModels ||
                    discovering ||
                    connection?['type'] == 'openclaw'
                ? null
                : discover,
            icon: const Icon(Icons.refresh),
            label: Text(discovering ? 'Discovering…' : 'Discover models')),
        if (models.isNotEmpty)
          DropdownButtonFormField<String>(
              key: ValueKey((connection?['id'], selectedModel?.id)),
              initialValue: selectedModel?.id,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Available models'),
              items: models
                  .map((m) =>
                      DropdownMenuItem(value: m.id, child: Text(m.displayName)))
                  .toList(),
              onChanged: (v) => setState(() {
                    if (!catalogCurrent || v == null) return;
                    selectedModel = models.singleWhere((m) => m.id == v);
                    model.text = selectedModel!.name;
                  })),
        const SizedBox(height: 16),
        TextField(
            controller: model,
            readOnly: connection?['type'] == 'hermes',
            onChanged: (_) => setState(() {
                  _userEditedModel = true;
                  if (connection?['type'] != 'hermes') selectedModel = null;
                }),
            decoration: InputDecoration(
                labelText: 'Model ID',
                helperText: connection?['type'] == 'hermes'
                    ? 'Choose a model from this server’s catalog.'
                    : 'Pick a discovered model or enter an exact ID.')),
        if (_isDirectConnection &&
            widget.controller.organization.personas.isNotEmpty) ...[
          const SizedBox(height: 16),
          KeyedSubtree(
            key: const Key('new-chat-persona'),
            child: DropdownButtonFormField<String>(
                key: ValueKey((
                  _effectivePersonaId,
                  widget.controller.organization.personas.length,
                )),
                initialValue: _effectivePersonaId ?? '',
                isExpanded: true,
                decoration:
                    const InputDecoration(labelText: 'Assistant persona'),
                items: [
                  const DropdownMenuItem(
                      value: '', child: Text('Custom instructions')),
                  for (final persona in widget.controller.organization.personas)
                    DropdownMenuItem(
                        value: persona.id,
                        child: Text(persona.name,
                            overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (value) => setState(
                    () => selectedPersonaId = value == '' ? null : value)),
          ),
        ],
        const SizedBox(height: 16),
        if (_effectivePersonaId == null)
          TextField(
              controller: prompt,
              maxLines: 4,
              decoration: const InputDecoration(
                  labelText: 'System prompt (optional)',
                  alignLabelWithHint: true))
        else
          Text(
            widget.controller.organization.personas
                    .where((p) => p.id == _effectivePersonaId)
                    .firstOrNull
                    ?.instructions ??
                '',
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        const SizedBox(height: 16),
        const Text(
            'This conversation stays on its original connection. Direct-model context is managed on this device.'),
        if (error != null)
          Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(error!,
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error))),
        const SizedBox(height: 24),
        FilledButton(
            onPressed: connection == null ||
                    connection?['type'] == 'openclaw' ||
                    model.text.trim().isEmpty ||
                    (connection?['type'] == 'hermes' &&
                        (selectedModel == null || !catalogCurrent)) ||
                    starting
                ? null
                : start,
            child: const Text('Start conversation')),
      ]));
}
