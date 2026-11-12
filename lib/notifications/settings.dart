import 'package:flutter/material.dart';
import 'reply_notifications.dart';

class NotificationSettingsButton extends StatelessWidget {
  const NotificationSettingsButton({super.key, required this.notifications});
  final ReplyNotifications notifications;
  @override
  Widget build(BuildContext context) => IconButton(
      tooltip: 'Notifications',
      icon: const Icon(Icons.notifications_outlined),
      onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => _Settings(notifications: notifications))));
}

class _Settings extends StatelessWidget {
  const _Settings({required this.notifications});
  final ReplyNotifications notifications;
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: ListenableBuilder(
          listenable: notifications,
          builder: (context, _) =>
              ListView(padding: const EdgeInsets.all(20), children: [
                SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Background replies'),
                    value: notifications.enabled,
                    onChanged: !notifications.supported
                        ? null
                        : (value) async {
                            final ok = await notifications.setEnabled(value);
                            if (!ok && context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text(
                                          'Could not change notifications. Check Android notification settings.')));
                            }
                          }),
                Text(notifications.supported
                    ? 'Off by default. Alerts only for replies received while Saathi is in the background. No message text is shown. Android permission and channel settings are respected.'
                    : 'Local OS notifications are currently supported on Android only.'),
                const SizedBox(height: 16),
                const Text(
                    'Delivery is not guaranteed when the app is killed or Android Doze restricts networking. This is not push messaging. Independent server jobs need a future gateway/push integration.'),
              ])));
}
