import 'package:flutter_test/flutter_test.dart';
import 'package:ridescreen_ios/qr.dart';

void main() {
  test('parses the Carbit pairing QR', () {
    final q = DashQr.parse('http://www.carbit.com.cn/downsdk/657/658/_sdk?modelid=37416&sn=peTz&action=9'
        '&ssid=CFMOTO-f46457&pwd=59a9cddc94&auth=wpa2-psk&mac=6C:09:4A:0F:6C:F8');
    expect(q?.ssid, 'CFMOTO-f46457');
    expect(q?.password, '59a9cddc94');
    expect(q?.action, 9);
  });
  test('rejects text that is not a pairing link', () {
    expect(DashQr.parse('hello'), isNull);
    expect(DashQr.parse('http://x/?ssid=a'), isNull);
  });
}
