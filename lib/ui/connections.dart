import 'package:flutter/material.dart';
import '../update_host.dart';
import '../notifications/settings.dart';
import '../core/saathi_core.dart';
import 'chat_controller.dart';
import 'remote_sessions.dart';

const providerLabels = {
  'openai': 'OpenAI-compatible',
  'anthropic': 'Anthropic',
  'gemini': 'Gemini',
  'hermes': 'Hermes',
  'openclaw': 'OpenClaw'
};

class ConnectionsPage extends StatefulWidget {
  const ConnectionsPage({super.key, required this.controller});
  final ChatController controller;
  @override
  State<ConnectionsPage> createState() => _ConnectionsPageState();
}

class _ConnectionsPageState extends State<ConnectionsPage> {
  ChatController get controller => widget.controller;
  String? opened;
  Future<void> action(Map<String, dynamic> c, String action) async {
    setState(() => opened = null);
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
      appBar: AppBar(title: const Text('Connections'), actions: [
        if (controller.notifications != null)
          NotificationSettingsButton(notifications: controller.notifications!),
        const UpdateSettingsButton()
      ]),
      body: ListenableBuilder(
          listenable: controller,
          builder: (context, _) =>
              ListView(padding: const EdgeInsets.all(20), children: [
                const Text('Your models, your connections',
                    style:
                        TextStyle(fontSize: 24, fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                const Text(
                    'Keys are held in platform secure storage. Chat history is stored on this device. Existing conversations stay bound to their original connection.'),
                const SizedBox(height: 20),
                for (final c in controller.connections)
                  GestureDetector(
                      onHorizontalDragUpdate: (d) {
                        if (d.delta.dx < -2) setState(() => opened = c['id']);
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
                                              constraints: const BoxConstraints(
                                                  minWidth: 48, minHeight: 48),
                                              onPressed: controller
                                                      .canChangeConnections
                                                  ? () => action(c, a)
                                                  : null,
                                              icon: Icon(
                                                  a == 'Edit'
                                                      ? Icons.edit_outlined
                                                      : Icons.delete_outline,
                                                  semanticLabel: a)))
                                  ])),
                            TweenAnimationBuilder<double>(
                                key: ValueKey('slide-${c['id']}'),
                                duration: const Duration(milliseconds: 180),
                                tween: Tween(
                                    begin: 0,
                                    end: opened == c['id'] ? -160 : 0),
                                builder: (_, x, child) => Transform.translate(
                                    offset: Offset(x, 0), child: child),
                                child: Material(
                                    color: Theme.of(context)
                                        .scaffoldBackgroundColor,
                                    child: ListTile(
                                        contentPadding: EdgeInsets.zero,
                                        leading: const Icon(Icons.dns_outlined),
                                        title: Text(c['name']),
                                        trailing: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              if (c['type'] == 'hermes')
                                                IconButton(
                                                    tooltip:
                                                        'Browse remote sessions',
                                                    icon: const Icon(
                                                        Icons.cloud_outlined),
                                                    onPressed: () => Navigator.push(
                                                        context,
                                                        MaterialPageRoute<void>(
                                                            builder: (_) =>
                                                                RemoteSessionsPage(
                                                                    controller:
                                                                        controller,
                                                                    connection:
                                                                        c)))),
                                              PopupMenuButton<String>(
                                                  tooltip: 'Connection actions',
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
                                                              child: Text(a))
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
                                builder: (_) =>
                                    AddConnectionPage(controller: controller))),
                    icon: const Icon(Icons.add),
                    label: const Text('Add connection')),
              ])));
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
  String? error;
  bool saving = false, showKey = false, keyReady = false, clearKey = false;
  String? initialKey;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final c = widget.connection;
    if (c == null) {
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
      final value =
          await widget.controller.store.secrets.read(widget.connection!['id']);
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
    WidgetsBinding.instance.removeObserver(this);
    name.dispose();
    url.dispose();
    keyInput.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (!form.currentState!.validate()) return;
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
                    .map((e) =>
                        DropdownMenuItem(value: e.key, child: Text(e.value)))
                    .toList(),
                onChanged: (v) => setState(() => type = v!)),
            const SizedBox(height: 18),
            TextFormField(
                controller: url,
                autocorrect: false,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                    labelText: 'API base URL',
                    hintText: 'https://api.example.com'),
                validator: (v) {
                  final uri = Uri.tryParse(v!.trim());
                  if (uri == null ||
                      !['http', 'https'].contains(uri.scheme) ||
                      uri.host.isEmpty ||
                      uri.userInfo.isNotEmpty ||
                      uri.hasQuery ||
                      uri.hasFragment) {
                    return 'Use an http(s) URL without credentials or query';
                  }
                  if (uri.scheme == 'http' &&
                      !['localhost', '127.0.0.1', '::1', '[::1]']
                          .contains(uri.host)) {
                    return 'Use HTTPS for remote servers. HTTP is only supported on loopback.';
                  }
                  return null;
                }),
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
                onChanged: (_) => clearKey = false,
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
                'Use HTTPS for remote servers. HTTP sends messages and credentials without encryption. Hermes and OpenClaw support depends on the server protocol; unsupported operations are reported, not simulated.'),
            if (error != null)
              Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error))),
            const SizedBox(height: 24),
            FilledButton(
                onPressed: saving || !keyReady ? null : save,
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
  const NewChatPage({super.key, required this.controller});
  final ChatController controller;
  @override
  State<NewChatPage> createState() => _NewChatPageState();
}

class _NewChatPageState extends State<NewChatPage> {
  Map<String, dynamic>? connection;
  List<ModelInfo> models = [];
  final model = TextEditingController(), prompt = TextEditingController();
  String? error;
  bool discovering = false, starting = false;
  @override
  void initState() {
    super.initState();
    if (widget.controller.connections.isNotEmpty) {
      connection = widget.controller.connections.first;
    }
  }

  @override
  void dispose() {
    model.dispose();
    prompt.dispose();
    super.dispose();
  }

  Future<void> discover() async {
    final target = connection!;
    setState(() {
      discovering = true;
      error = null;
    });
    try {
      final result = await widget.controller.discover(target);
      if (mounted && connection == target) {
        setState(() {
          models = result;
          if (result.isEmpty) {
            error = 'No models returned. Enter a model ID manually.';
          }
        });
      }
    } on ProviderException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => error =
            'Discovery failed. Check the URL and credentials, or enter a model ID.');
      }
    } finally {
      if (mounted) setState(() => discovering = false);
    }
  }

  Future<void> start() async {
    setState(() {
      starting = true;
      error = null;
    });
    try {
      await widget.controller
          .newSession(connection!, model.text.trim(), prompt.text.trim());
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
            initialValue: connection?['id'],
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Connection'),
            items: widget.controller.connections
                .map((c) => DropdownMenuItem<String>(
                    value: c['id'], child: Text(c['name'])))
                .toList(),
            onChanged: discovering
                ? null
                : (id) => setState(() {
                      connection = widget.controller.connections
                          .firstWhere((c) => c['id'] == id);
                      models = [];
                      model.clear();
                      error = null;
                    })),
        if (connection?['type'] == 'openclaw')
          const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text(
                  'OpenClaw requires its native gateway. This build cannot discover models or start a conversation on that protocol.')),
        if (connection?['type'] == 'hermes')
          const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text(
                  'This starts a new app-owned conversation. To inspect an existing desktop / CLI session, use Browse remote sessions in Connections. Live attachment is not available.')),
        const SizedBox(height: 16),
        OutlinedButton.icon(
            onPressed: connection == null ||
                    discovering ||
                    connection?['type'] == 'openclaw'
                ? null
                : discover,
            icon: const Icon(Icons.refresh),
            label: Text(discovering ? 'Discovering…' : 'Discover models')),
        if (models.isNotEmpty)
          DropdownButtonFormField<String>(
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Available models'),
              items: models
                  .map((m) => DropdownMenuItem(
                      value: m.name, child: Text(m.displayName)))
                  .toList(),
              onChanged: (v) => setState(() => model.text = v!)),
        const SizedBox(height: 16),
        TextField(
            controller: model,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
                labelText: 'Model ID',
                helperText: 'Pick a discovered model or enter an exact ID.')),
        const SizedBox(height: 16),
        TextField(
            controller: prompt,
            maxLines: 4,
            decoration: const InputDecoration(
                labelText: 'System prompt (optional)',
                alignLabelWithHint: true)),
        const SizedBox(height: 16),
        const Text(
            'This conversation keeps its connection, model and instructions. Start a new conversation to change them. Direct-model context is managed on this device.'),
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
                    starting
                ? null
                : start,
            child: const Text('Start conversation')),
      ]));
}
