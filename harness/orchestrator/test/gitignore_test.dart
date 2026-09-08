import 'package:e2e_orchestrator/src/util/gitignore.dart';
import 'package:test/test.dart';

void main() {
  const rules = '''
# comment
.dart_tool/
runs/
e2e.local.yaml
secrets/*
!secrets/README.md
*service-account*.json
*-adminsdk-*.json
example/app/lib/firebase_options.dart
''';

  bool ignored(String p) => isIgnoredByRules(p, rules);

  test('exact and directory rules', () {
    expect(ignored('e2e.local.yaml'), isTrue);
    expect(ignored('runs/2026-01-01/summary.json'), isTrue);
    expect(ignored('.dart_tool/package_config.json'), isTrue);
    expect(ignored('e2e.yaml'), isFalse);
  });

  test('directory wildcard covers files inside', () {
    expect(ignored('secrets/firebase-service-account.json'), isTrue);
    expect(ignored('secrets/anything.pem'), isTrue);
  });

  test('negation re-includes a specific file', () {
    expect(ignored('secrets/README.md'), isFalse);
  });

  test('glob patterns match basenames at any depth', () {
    expect(ignored('firebase-service-account.json'), isTrue);
    expect(ignored('some/dir/my-service-account-key.json'), isTrue);
    expect(
      ignored('my-project-1234-firebase-adminsdk-ab12c-3d4e5f6789.json'),
      isTrue,
      reason: 'a real admin SDK key filename must be covered',
    );
    expect(ignored('harmless.json'), isFalse);
  });

  test('anchored paths only match at their location', () {
    expect(ignored('example/app/lib/firebase_options.dart'), isTrue);
    expect(ignored('other/firebase_options.dart'), isFalse);
  });

  test('double-star crosses directories', () {
    expect(isIgnoredByRules('a/b/c/key.pem', '**/key.pem'), isTrue);
    expect(isIgnoredByRules('key.pem', '**/key.pem'), isTrue);
  });
}
