import 'package:flutter/material.dart';
import '../gateway/hermes_gateway.dart';
import 'dashboard_store.dart';

const _failure =
    'Could not complete this securely. Check the dashboard, sign-in and storage, then try again.';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key, required this.store});
  final DashboardStore store;
  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  List<DashboardConnection> entries = [];
  String? error;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final value = await widget.store.load();
      if (mounted) setState(() => entries = value);
    } catch (_) {
      if (mounted) setState(() => error = _failure);
    }
  }

  @override
  void dispose() {
    widget.store.close();
    super.dispose();
  }

  Future<void> open(DashboardConnection e) async {
    setState(() => busy = true);
    try {
      final identity = await widget.store.open(e);
      if (!mounted) return;
      await Navigator.push(
          context,
          MaterialPageRoute<void>(
              builder: (_) => _IdentityPage(
                  store: widget.store,
                  entry: e,
                  identity: identity.displayName)));
    } catch (_) {
      if (mounted) setState(() => error = _failure);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Hermes dashboards')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        const Text('Hermes dashboard — username & password'),
        const SizedBox(height: 12),
        const Text(
            'Separate from API-server key connections. View native sessions read-only; no prompts or approvals. Cookies stay in secure storage.'),
        if (error != null) Text(error!),
        for (final e in entries)
          ListTile(
              title: Text(e.name),
              subtitle: Text(e.baseUrl),
              onTap: busy ? null : () => open(e),
              trailing: IconButton(
                  tooltip: 'Sign out and remove',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: busy
                      ? null
                      : () async {
                          setState(() => busy = true);
                          try {
                            await widget.store.remove(e);
                            await load();
                          } catch (_) {
                            if (mounted) setState(() => error = _failure);
                          } finally {
                            if (mounted) setState(() => busy = false);
                          }
                        })),
        FilledButton(
            onPressed: busy
                ? null
                : () async {
                    await Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                            builder: (_) =>
                                DashboardLoginPage(store: widget.store)));
                    await load();
                  },
            child: const Text('Add dashboard')),
        const Text(
            'Sign out forgets this device’s session. It does not revoke copied Basic-provider tokens on other devices.')
      ]));
}

class DashboardLoginPage extends StatefulWidget {
  const DashboardLoginPage({super.key, required this.store});
  final DashboardStore store;
  @override
  State<DashboardLoginPage> createState() => _DashboardLoginPageState();
}

class _DashboardLoginPageState extends State<DashboardLoginPage> {
  final form = GlobalKey<FormState>();
  final cancellation = DashboardLoginCancellation();
  final name = TextEditingController(),
      url = TextEditingController(),
      username = TextEditingController(),
      password = TextEditingController();
  bool busy = false;
  String? error;
  @override
  void dispose() {
    cancellation.cancel();
    name.dispose();
    url.dispose();
    username.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> login() async {
    if (!form.currentState!.validate()) {
      password.clear();
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.store.signIn(
          cancellation: cancellation,
          name: name.text.trim(),
          baseUrl: url.text.trim(),
          username: username.text,
          password: password.text);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) setState(() => error = _failure);
    } finally {
      if (mounted) {
        password.clear();
        setState(() => busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) cancellation.cancel();
      },
      child: Scaffold(
          appBar: AppBar(title: const Text('Dashboard sign-in')),
          body: Form(
              key: form,
              child: ListView(padding: const EdgeInsets.all(20), children: [
                const Text('Hermes dashboard — username & password'),
                const Text(
                    'Not an API-server key or HTTP Basic connection. HTTPS required except loopback.'),
                for (final field in [
                  (name, 'Connection name'),
                  (url, 'Dashboard URL'),
                  (username, 'Username'),
                  (password, 'Password')
                ])
                  Padding(
                      padding: const EdgeInsets.only(top: 18),
                      child: TextFormField(
                          controller: field.$1,
                          enabled: !busy,
                          obscureText: field.$1 == password,
                          autocorrect: false,
                          enableSuggestions: false,
                          keyboardType: field.$1 == url
                              ? TextInputType.url
                              : TextInputType.text,
                          decoration: InputDecoration(labelText: field.$2),
                          validator: (v) =>
                              v == null || v.isEmpty ? 'Required' : null)),
                if (error != null) Text(error!),
                const SizedBox(height: 24),
                FilledButton(
                    onPressed: busy ? null : login,
                    child: Text(busy ? 'Signing in…' : 'Sign in securely'))
              ]))));
}

class _IdentityPage extends StatefulWidget {
  const _IdentityPage(
      {required this.store, required this.entry, required this.identity});
  final DashboardStore store;
  final DashboardConnection entry;
  final String identity;
  @override
  State<_IdentityPage> createState() => _IdentityPageState();
}

class _IdentityPageState extends State<_IdentityPage> {
  bool busy = false;
  String? error;
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text(widget.entry.name)),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Text('Signed in as ${widget.identity}'),
        if (error != null) Text(error!),
        FilledButton(
            onPressed: busy
                ? null
                : () async {
                    setState(() => busy = true);
                    try {
                      final gateway = await widget.store.connect(widget.entry);
                      if (!context.mounted) {
                        await gateway.dispose();
                        return;
                      }
                      await Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                              builder: (_) =>
                                  DashboardSessionsPage(gateway: gateway)));
                    } catch (_) {
                      if (mounted) {
                        setState(() => error =
                            'Canonical gateway unavailable or unsupported. No session was imported or sent.');
                      }
                    } finally {
                      if (mounted) setState(() => busy = false);
                    }
                  },
            child: const Text('View sessions (read-only)'))
      ]));
}

class DashboardSessionsPage extends StatefulWidget {
  const DashboardSessionsPage({super.key, required this.gateway});
  final HermesGatewayClient gateway;
  @override
  State<DashboardSessionsPage> createState() => _DashboardSessionsPageState();
}

class _DashboardSessionsPageState extends State<DashboardSessionsPage> {
  bool stored = false, busy = false;
  String? error;
  List<GatewaySession> sessions = [];
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    widget.gateway.dispose();
    super.dispose();
  }

  Future<void> load() async {
    setState(() {
      busy = true;
      sessions = [];
      error = null;
    });
    try {
      final rows = await widget.gateway.listSessions(stored: stored);
      if (mounted) {
        setState(() {
          sessions = rows;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => error =
            'Session list unavailable. Gateway may be disconnected or unsupported.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Sessions · read-only')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        SwitchListTile(
            title: const Text('Stored sessions'),
            value: stored,
            onChanged: busy
                ? null
                : (v) {
                    stored = v;
                    load();
                  }),
        const Text(
            'Up to 50 sessions per scope. Snapshots only; refresh explicitly. No sending or approvals.'),
        if (error != null) Text(error!),
        if (busy) const LinearProgressIndicator(),
        if (!busy && sessions.isEmpty)
          const Text('No sessions in this window.'),
        for (final s in sessions)
          ListTile(
              title: Text(s.title.isEmpty ? s.id : s.title),
              subtitle: Text(s.running ? 'Running' : 'Idle'),
              onTap: busy
                  ? null
                  : () async {
                      setState(() => busy = true);
                      try {
                        final snapshot = await widget.gateway.attach(s.id);
                        if (!context.mounted) return;
                        await Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                                builder: (_) => _SnapshotPage(
                                    gateway: widget.gateway,
                                    snapshot: snapshot)));
                      } catch (_) {
                        if (mounted) {
                          setState(() => error =
                              'Snapshot unavailable, oversized or unsupported. Nothing was imported.');
                        }
                      } finally {
                        if (mounted) setState(() => busy = false);
                      }
                    }),
        OutlinedButton(
            onPressed: busy ? null : load, child: const Text('Refresh list'))
      ]));
}

class _SnapshotPage extends StatefulWidget {
  const _SnapshotPage({required this.gateway, required this.snapshot});
  final HermesGatewayClient gateway;
  final GatewaySnapshot snapshot;
  @override
  State<_SnapshotPage> createState() => _SnapshotPageState();
}

class _SnapshotPageState extends State<_SnapshotPage> {
  late GatewaySnapshot snapshot = widget.snapshot;
  bool busy = false;
  String? error;
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Session snapshot · read-only')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        const Text(
            'Read-only snapshot, not a live chat. Text only; embedded images are never fetched.'),
        if (snapshot.needsUserAction)
          const Text(
              'Action required. Use another supported client for approvals or clarification.'),
        Text(snapshot.running
            ? 'Server session is running; refresh for latest snapshot.'
            : 'Server session was idle at snapshot time.'),
        if (error != null) Text(error!),
        for (final message in snapshot.messages)
          Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(message.role,
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    SelectableText(message.text)
                  ])),
        OutlinedButton(
            onPressed: busy
                ? null
                : () async {
                    setState(() => busy = true);
                    try {
                      final fresh =
                          await widget.gateway.attach(snapshot.sessionId);
                      if (mounted) {
                        setState(() {
                          snapshot = fresh;
                          error = null;
                        });
                      }
                    } catch (_) {
                      if (mounted) {
                        setState(() => error =
                            'Cannot refresh this snapshot. It may be oversized or the gateway disconnected.');
                      }
                    } finally {
                      if (mounted) setState(() => busy = false);
                    }
                  },
            child: const Text('Refresh snapshot'))
      ]));
}
