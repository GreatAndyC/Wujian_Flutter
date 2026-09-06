import 'package:flutter_test/flutter_test.dart';
import 'package:icheck/shared/app_links.dart';

void main() {
  test('privacy policy link stays on the public HTTPS article', () {
    final uri = Uri.parse(appPrivacyPolicyUrl);

    expect(uri.scheme, 'https');
    expect(uri.host, 'caoyueyang.org');
    expect(uri.path, '/2026/09/06/wujian-privacy-policy/');
  });
}
