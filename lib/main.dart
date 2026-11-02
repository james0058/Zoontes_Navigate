import 'dart:async';

import 'package:easyconn_core/easyconn_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'nav_page.dart';
import 'qr.dart';

void main() => runApp(const RideScreenApp());

class RideScreenApp extends StatelessWidget {
  const RideScreenApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'RideScreen iOS',
        theme: ThemeData(colorSchemeSeed: const Color(0xFFC8F240), brightness: Brightness.dark, useMaterial3: true),
        home: const HomePage(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _qr = TextEditingController();
  final _host = TextEditingController();
  final _logs = <String>[];
  StreamSubscription<SessionEvent>? _sub;
  SessionPhase _phase = SessionPhase.idle;
  String? _failure;
  DashQr? _parsed;
  bool _dim = false;
  final _navStatus = ValueNotifier<String>('');
  bool _voice = true;
  bool _map = true;
  String _layout = 'full';

  @override
  void initState() {
    super.initState();
    _sub = EasyconnCore.events.listen((e) {
      setState(() {
        if (e.log != null) {
          _logs.add(e.log!);
          if (_logs.length > 300) _logs.removeAt(0);
        }
        if (e.nav != null) _navStatus.value = e.nav!;
        if (e.phase != null) {
          _phase = e.phase!;
          _failure = e.failure;
        }
      });
    });
    _qr.addListener(() => setState(() => _parsed = DashQr.parse(_qr.text)));
  }

  @override
  void dispose() {
    _sub?.cancel();
    _qr.dispose();
    _host.dispose();
    _navStatus.dispose();
    super.dispose();
  }

  bool get _running => _phase != SessionPhase.idle && _phase != SessionPhase.failed;

  Future<void> _scan() async {
    final raw = await EasyconnCore.scanQr();
    if (raw != null) _qr.text = raw;
  }

  Future<void> _toggle() async {
    try {
      if (_running) {
        await EasyconnCore.stop();
      } else {
        _logs.clear();
        await EasyconnCore.setLayout(_layout);
        await EasyconnCore.start(
          host: _host.text.trim().isEmpty ? null : _host.text.trim(),
          source: _map ? 'map' : 'test',
        );
      }
    } on PlatformException catch (e) {
      setState(() => _failure = e.message);
    }
  }

  String get _label => switch (_phase) {
        SessionPhase.idle => 'Not connected',
        SessionPhase.probing => 'Contacting the dash…',
        SessionPhase.waiting => 'Waiting for the dash to connect',
        SessionPhase.handshaking => 'Handshake in progress',
        SessionPhase.streaming => 'Streaming to the dash',
        SessionPhase.failed => 'Failed: ${_failure ?? 'unknown'}',
      };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('RideScreen iOS')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ValueListenableBuilder<String>(
              valueListenable: _navStatus,
              builder: (_, status, _) => Row(children: [
                FilledButton.tonalIcon(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => NavPage(navStatus: _navStatus))),
                  icon: const Icon(Icons.navigation_outlined),
                  label: Text(status.isEmpty ? 'Navigate' : 'Navigation'),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Voice guidance',
                  onPressed: () {
                    setState(() => _voice = !_voice);
                    EasyconnCore.setVoice(_voice);
                  },
                  icon: Icon(_voice ? Icons.volume_up : Icons.volume_off),
                ),
                Expanded(child: Text(status, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall)),
              ]),
            ),
            const SizedBox(height: 12),
            Text('1. Scan the QR on the dash, or paste its link', style: t.textTheme.titleSmall),
            const SizedBox(height: 8),
            TextField(
              controller: _qr,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'http://www.carbit.com.cn/…?ssid=…&pwd=…'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(onPressed: _running ? null : _scan, icon: const Icon(Icons.qr_code_scanner), label: const Text('Scan QR')),
            if (_parsed != null) ...[
              const SizedBox(height: 12),
              Text('2. Join this Wi-Fi in Settings, then come back', style: t.textTheme.titleSmall),
              Card(
                child: ListTile(
                  title: Text(_parsed!.ssid),
                  subtitle: Text('Password: ${_parsed!.password}'),
                  trailing: IconButton(
                    icon: const Icon(Icons.copy),
                    onPressed: () => Clipboard.setData(ClipboardData(text: _parsed!.password)),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            TextField(
              controller: _host,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Dash IP (optional)',
                hintText: 'e.g. 192.168.3.1 — empty = detect automatically',
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Show the map (GPS + mobile data)'),
              subtitle: const Text('Off = test pattern (clock)'),
              value: _map,
              onChanged: _running ? null : (v) => setState(() => _map = v),
            ),
            if (_map)
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'full', label: Text('3 panels')),
                  ButtonSegment(value: 'wide', label: Text('Wide map')),
                ],
                selected: {_layout},
                onSelectionChanged: (v) {
                  setState(() => _layout = v.first);
                  EasyconnCore.setLayout(_layout);
                },
              ),
            if (_map)
              Row(children: [
                const Text('Zoom'),
                IconButton(onPressed: () => EasyconnCore.zoom(-0.5), icon: const Icon(Icons.remove_circle_outline)),
                IconButton(onPressed: () => EasyconnCore.zoom(0.5), icon: const Icon(Icons.add_circle_outline)),
                const Text('(auto: closer when slow, wider when fast)', style: TextStyle(fontSize: 12)),
              ]),
            const SizedBox(height: 4),
            Row(children: [
              FilledButton(onPressed: _toggle, child: Text(_running ? 'Stop' : 'Connect')),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _running
                    ? () {
                        setState(() => _dim = !_dim);
                        EasyconnCore.dim(_dim);
                      }
                    : null,
                child: Text(_dim ? 'Undim' : 'Dim'),
              ),
              const SizedBox(width: 16),
              Expanded(child: Text(_label, style: t.textTheme.bodyMedium)),
            ]),
            const SizedBox(height: 12),
            Text('Log', style: t.textTheme.titleSmall),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
                child: ListView(
                  reverse: true,
                  children: [
                    for (final l in _logs.reversed) Text(l, style: const TextStyle(fontFamily: 'Menlo', fontSize: 11)),
                  ],
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
