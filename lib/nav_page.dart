import 'dart:async';

import 'package:easyconn_core/easyconn_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// Search a place (or drop a pin on a map) and start navigating to it.
class NavPage extends StatefulWidget {
  const NavPage({super.key, required this.navStatus});
  final ValueListenable<String> navStatus;

  @override
  State<NavPage> createState() => _NavPageState();
}

class _NavPageState extends State<NavPage> {
  final _q = TextEditingController();
  Timer? _debounce;
  List<Place> _results = const [];
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () => _search(text));
  }

  Future<void> _search(String text) async {
    if (text.trim().length < 2) {
      setState(() => _results = const []);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await EasyconnCore.search(text);
      if (!mounted) return;
      setState(() {
        _results = r;
        _error = r.isEmpty ? 'Nothing found. Try another name, or pin it on the map.' : null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Search failed. Check mobile data.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _go(double lat, double lon, String name) async {
    await EasyconnCore.navigate(lat, lon, name);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _pickOnMap() async {
    final here = await EasyconnCore.lastLocation();
    if (!mounted) return;
    final picked = await Navigator.of(context).push<LatLng>(
      MaterialPageRoute(builder: (_) => _PinPage(start: here == null ? null : LatLng(here.lat, here.lon))),
    );
    if (picked != null) {
      await _go(picked.latitude, picked.longitude, 'Pinned place');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Navigate')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ValueListenableBuilder<String>(
              valueListenable: widget.navStatus,
              builder: (_, status, _) => status.isEmpty
                  ? const SizedBox.shrink()
                  : Card(
                      child: ListTile(
                        title: Text(status),
                        trailing: TextButton(
                          onPressed: () async {
                            final nav = Navigator.of(context);
                            await EasyconnCore.stopNavigation();
                            nav.pop();
                          },
                          child: const Text('Stop'),
                        ),
                      ),
                    ),
            ),
            TextField(
              controller: _q,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onChanged: _onChanged,
              onSubmitted: _search,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                hintText: 'Where to? (place, address)',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _busy ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))) : null,
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(onPressed: _pickOnMap, icon: const Icon(Icons.push_pin_outlined), label: const Text('Drop a pin on the map')),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: t.textTheme.bodyMedium)),
            Expanded(
              child: ListView.separated(
                itemCount: _results.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final p = _results[i];
                  return ListTile(
                    leading: const Icon(Icons.place_outlined),
                    title: Text(p.name),
                    subtitle: p.detail.isEmpty ? null : Text(p.detail),
                    onTap: () => _go(p.lat, p.lon, p.name),
                  );
                },
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _PinPage extends StatefulWidget {
  const _PinPage({this.start});
  final LatLng? start;

  @override
  State<_PinPage> createState() => _PinPageState();
}

class _PinPageState extends State<_PinPage> {
  LatLng? _pin;

  @override
  Widget build(BuildContext context) {
    final center = widget.start ?? const LatLng(13.7563, 100.5018);
    return Scaffold(
      appBar: AppBar(title: const Text('Tap to drop a pin')),
      body: Stack(children: [
        FlutterMap(
          options: MapOptions(
            initialCenter: center,
            initialZoom: 15,
            onTap: (_, p) => setState(() => _pin = p),
            onLongPress: (_, p) => setState(() => _pin = p),
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'dev.ridescreen.ridescreenIos',
            ),
            if (widget.start != null)
              MarkerLayer(markers: [
                Marker(point: widget.start!, width: 22, height: 22, child: const Icon(Icons.my_location, color: Colors.blue, size: 22)),
              ]),
            if (_pin != null)
              MarkerLayer(markers: [
                Marker(point: _pin!, width: 44, height: 44, alignment: Alignment.topCenter, child: const Icon(Icons.location_pin, color: Colors.red, size: 44)),
              ]),
            const RichAttributionWidget(attributions: [TextSourceAttribution('© OpenStreetMap contributors')]),
          ],
        ),
        if (_pin != null)
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton.icon(
                  onPressed: () => Navigator.of(context).pop(_pin),
                  icon: const Icon(Icons.navigation),
                  label: const Text('Navigate here'),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}
