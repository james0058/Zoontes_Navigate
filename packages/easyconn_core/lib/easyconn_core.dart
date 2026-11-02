import 'dart:async';

import 'package:flutter/services.dart';

enum SessionPhase { idle, probing, waiting, handshaking, streaming, failed }

class SessionEvent {
  const SessionEvent({this.log, this.phase, this.failure, this.nav});
  final String? log;
  /// Navigation status line ("Turn left in 300 m · 2.1 km left to …"); empty when not navigating.
  final String? nav;
  final SessionPhase? phase;
  final String? failure;
}

/// Thin Dart face of the Swift EasyConnKit session (all protocol work happens natively).
class EasyconnCore {
  static const _method = MethodChannel('easyconn_core');
  static const _events = EventChannel('easyconn_core/events');

  /// Log lines and phase changes from the native session.
  static Stream<SessionEvent> get events => _events.receiveBroadcastStream().map((e) {
        final m = Map<String, dynamic>.from(e as Map);
        if (m['log'] != null) return SessionEvent(log: m['log'] as String);
        if (m['nav'] != null) return SessionEvent(nav: m['nav'] as String);
        final s = m['state'] as String;
        if (s.startsWith('failed')) {
          return SessionEvent(phase: SessionPhase.failed, failure: s.substring(s.indexOf(':') + 1).trim());
        }
        return SessionEvent(phase: SessionPhase.values.firstWhere((p) => p.name == s, orElse: () => SessionPhase.idle));
      });

  /// [source] is 'map' (GPS map dashboard) or 'test' (clock test pattern).
  static Future<void> start({String? host, String source = 'map', String? tileUrl}) =>
      _method.invokeMethod('start', {'host': ?host, 'source': source, 'tileUrl': ?tileUrl});
  /// Opens the camera; returns the QR text, or null if cancelled.
  static Future<String?> scanQr() => _method.invokeMethod<String>('scanQr');
  /// 'full' (speed | map | trip) or 'wide' (speed | wider map). Takes effect live.
  static Future<void> setLayout(String name) => _method.invokeMethod('layout', {'name': name});
  /// Changes the map zoom by [delta] levels on top of the automatic speed zoom; returns the new offset.
  static Future<double?> zoom(double delta) => _method.invokeMethod<double>('zoom', {'delta': delta});
  /// Searches places (Photon / OpenStreetMap), biased to the phone's position unless [lat]/[lon] are given.
  static Future<List<Place>> search(String query, {double? lat, double? lon}) async {
    final r = await _method.invokeMethod<List<Object?>>('search', {'query': query, 'lat': ?lat, 'lon': ?lon});
    return [for (final e in r ?? const []) Place.fromMap(Map<String, dynamic>.from(e as Map))];
  }

  /// Starts turn-by-turn navigation (route line + banner on the dash, spoken directions on the phone).
  static Future<void> navigate(double lat, double lon, String name) =>
      _method.invokeMethod('navigate', {'lat': lat, 'lon': lon, 'name': name});

  static Future<void> stopNavigation() => _method.invokeMethod('stopNavigation');
  static Future<void> setVoice(bool on) => _method.invokeMethod('voice', {'on': on});

  /// Last GPS position, or null before the first fix.
  static Future<({double lat, double lon})?> lastLocation() async {
    final r = await _method.invokeMethod<Map<Object?, Object?>>('lastLocation');
    return r == null ? null : (lat: r['lat'] as double, lon: r['lon'] as double);
  }

  static Future<void> dim(bool on) => _method.invokeMethod('dim', {'on': on});
  static Future<void> stop() => _method.invokeMethod('stop');
}

class Place {
  const Place({required this.name, required this.detail, required this.lat, required this.lon});
  final String name;
  final String detail;
  final double lat;
  final double lon;

  factory Place.fromMap(Map<String, dynamic> m) => Place(
        name: m['name'] as String,
        detail: m['detail'] as String,
        lat: (m['lat'] as num).toDouble(),
        lon: (m['lon'] as num).toDouble(),
      );
}
