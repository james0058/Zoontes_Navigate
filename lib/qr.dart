/// The dash's pairing QR is a URL whose query carries the Wi-Fi credentials.
class DashQr {
  const DashQr({required this.ssid, required this.password, this.action = 0, this.modelId});
  final String ssid;
  final String password;
  final int action;
  final String? modelId;

  static DashQr? parse(String raw) {
    final text = raw.trim();
    final q = text.indexOf('?');
    if (q < 0) return null;
    var query = text.substring(q + 1);
    final hash = query.indexOf('#');
    if (hash >= 0) query = query.substring(0, hash);
    final map = <String, String>{};
    for (final part in query.split('&')) {
      if (part.isEmpty) continue;
      final eq = part.indexOf('=');
      final k = (eq < 0 ? part : part.substring(0, eq)).toLowerCase();
      final v = eq < 0 ? '' : part.substring(eq + 1);
      map[k] = Uri.decodeQueryComponent(v);
    }
    final ssid = (map['ssid'] ?? '').trim();
    final pwd = map['pwd'] ?? '';
    if (ssid.isEmpty || pwd.isEmpty) return null;
    return DashQr(ssid: ssid, password: pwd, action: int.tryParse(map['action'] ?? '') ?? 0, modelId: map['modelid']);
  }
}
