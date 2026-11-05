import 'package:flutter/material.dart';

void main() => runApp(const IrisApp());

class IrisApp extends StatelessWidget {
  const IrisApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Iris',
        theme: ThemeData(
            colorScheme:
                ColorScheme.fromSeed(seedColor: const Color(0xFF6257D9)),
            useMaterial3: true),
        home: const ChatHome(),
      );
}

class ChatHome extends StatelessWidget {
  const ChatHome({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Iris'),
          actions: [
            IconButton(
                tooltip: 'Sessions',
                onPressed: () {},
                icon: const Icon(Icons.forum_outlined)),
            IconButton(
                tooltip: 'Connection settings',
                onPressed: () {},
                icon: const Icon(Icons.settings_outlined))
          ],
        ),
        body: const Center(child: Text('Your conversation starts here')),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Expanded(
                  child: TextField(
                      decoration: InputDecoration(
                          hintText: 'Message Hermes…',
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(24)),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 18, vertical: 12)))),
              const SizedBox(width: 8),
              IconButton.filled(
                  tooltip: 'Send',
                  onPressed: null,
                  icon: const Icon(Icons.arrow_upward)),
            ]),
          ),
        ),
      );
}
