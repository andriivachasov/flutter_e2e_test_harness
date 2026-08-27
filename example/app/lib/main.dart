import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// E2E configuration, injected by the orchestrator via --dart-define.
/// In production builds these keep their defaults. This tiny block is the
/// only e2e-specific code a target app needs in its lib/ (see playbook).
const kBackendUrl = String.fromEnvironment(
  'E2E_BACKEND_URL',
  defaultValue: 'http://127.0.0.1:8080',
);
const kRunId = String.fromEnvironment('E2E_RUN_ID', defaultValue: '');
const kTestId = String.fromEnvironment('E2E_TEST_ID', defaultValue: '');

/// Identity Toolkit base: the Auth emulator in e2e runs, Google's endpoint
/// otherwise. Sign-in uses the Firebase Auth REST API directly (D11), so the
/// app has no native Firebase SDK to configure per platform.
const kAuthUrl = String.fromEnvironment(
  'E2E_AUTH_URL',
  defaultValue: 'https://identitytoolkit.googleapis.com/v1',
);
const kFirebaseApiKey = String.fromEnvironment(
  'E2E_FIREBASE_API_KEY',
  defaultValue: 'REPLACE_WITH_WEB_API_KEY',
);

void main() => runApp(const E2EExampleApp());

// ---------------------------------------------------------------------------
// Auth + session
// ---------------------------------------------------------------------------

class Session {
  const Session({
    required this.uid,
    required this.email,
    required this.idToken,
    this.mode = 'restored',
  });
  final String uid;
  final String email;
  final String idToken;

  /// How this session came to be: 'registered' (account created just now),
  /// 'signed-in' (existing account) or 'restored' (from disk).
  final String mode;

  Map<String, Object?> toJson() => {'uid': uid, 'email': email, 'idToken': idToken};
  static Session fromJson(Map<String, dynamic> m) => Session(
        uid: m['uid'] as String,
        email: m['email'] as String,
        idToken: m['idToken'] as String,
      );
}

/// Email/password auth against Firebase Auth's REST API.
///
/// "Continue" semantics (D23): sign in; if the account does not exist yet,
/// register it — the regular sign-up flow — and continue. Test users are a
/// fixed pool the app itself brings into existence this way.
class AuthClient {
  AuthClient({required this.authUrl, required this.apiKey});
  final String authUrl;
  final String apiKey;

  Future<Session> continueWith(String email, String password) async {
    try {
      return await _call('accounts:signInWithPassword', email, password, 'signed-in');
    } on AuthException catch (e) {
      if (e.code == 'EMAIL_NOT_FOUND' || e.code == 'INVALID_LOGIN_CREDENTIALS') {
        try {
          return await _call('accounts:signUp', email, password, 'registered');
        } on AuthException catch (up) {
          // Existed after all (wrong password) → report the sign-in error.
          throw up.code == 'EMAIL_EXISTS' ? AuthException('INVALID_PASSWORD') : up;
        }
      }
      rethrow;
    }
  }

  Future<Session> _call(String method, String email, String password, String mode) async {
    final client = HttpClient();
    try {
      final req = await client.postUrl(Uri.parse('$authUrl/$method?key=$apiKey'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'email': email,
        'password': password,
        'returnSecureToken': true,
      }));
      final res = await req.close();
      final body = jsonDecode(await res.transform(utf8.decoder).join())
          as Map<String, dynamic>;
      if (res.statusCode != 200) {
        final message = (body['error'] as Map?)?['message'] ?? 'HTTP ${res.statusCode}';
        throw AuthException('$message');
      }
      return Session(
        uid: body['localId'] as String,
        email: body['email'] as String,
        idToken: body['idToken'] as String,
        mode: mode,
      );
    } finally {
      client.close();
    }
  }
}

class AuthException implements Exception {
  AuthException(this.message);
  final String message;

  /// The Identity Toolkit error code, e.g. `EMAIL_NOT_FOUND` from
  /// `EMAIL_NOT_FOUND` or `INVALID_LOGIN_CREDENTIALS : ...`.
  String get code => message.split(RegExp(r'[\s:]')).first;
  @override
  String toString() => message;
}

/// Persists the session on device, so a relaunch restores it — which is
/// exactly what the harness's app-level reset (R9a) has to wipe.
class SessionStore {
  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/session.json');
  }

  Future<Session?> load() async {
    try {
      final f = await _file();
      if (!f.existsSync()) return null;
      return Session.fromJson(
        jsonDecode(f.readAsStringSync()) as Map<String, dynamic>,
      );
    } on Object {
      return null;
    }
  }

  Future<void> save(Session s) async =>
      (await _file()).writeAsString(jsonEncode(s.toJson()));

  Future<void> clear() async {
    final f = await _file();
    if (f.existsSync()) f.deleteSync();
  }
}

// ---------------------------------------------------------------------------
// Backend API
// ---------------------------------------------------------------------------

class ApiClient {
  ApiClient(this.baseUrl, this.session);

  final String baseUrl;
  final Session session;
  final HttpClient _client = HttpClient();

  Future<Map<String, dynamic>> _json(String method, String path,
      [Map<String, Object?>? body]) async {
    final req = await _client.openUrl(method, Uri.parse('$baseUrl$path'));
    req.headers.set('Authorization', 'Bearer ${session.idToken}');
    // Log correlation (R13): every request carries run/test ids.
    if (kRunId.isNotEmpty) req.headers.set('X-E2E-Run-Id', kRunId);
    if (kTestId.isNotEmpty) req.headers.set('X-E2E-Test-Id', kTestId);
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode >= 400) {
      throw HttpException('$method $path -> ${res.statusCode}: $text');
    }
    return jsonDecode(text) as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> notes() async =>
      ((await _json('GET', '/api/notes'))['notes'] as List)
          .cast<Map<String, dynamic>>();

  Future<void> addNote(String text) => _json('POST', '/api/notes', {'text': text});

  Future<List<Map<String, dynamic>>> messages(String withEmail) async =>
      ((await _json('GET', '/api/messages?with=${Uri.encodeQueryComponent(withEmail)}'))['messages']
              as List)
          .cast<Map<String, dynamic>>();

  Future<void> sendMessage(String to, String text) =>
      _json('POST', '/api/messages', {'to': to, 'text': text});
}

// ---------------------------------------------------------------------------
// UI
// ---------------------------------------------------------------------------

class E2EExampleApp extends StatelessWidget {
  const E2EExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'E2E Example',
      home: AuthGate(),
    );
  }
}

/// Restores a persisted session or shows the sign-in page.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  final SessionStore _store = SessionStore();
  Session? _session;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _store.load().then((s) {
      if (mounted) setState(() {
        _session = s;
        _loaded = true;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(key: Key('session_loading')),
        ),
      );
    }
    final session = _session;
    if (session == null) {
      return SignInPage(onSignedIn: (s) async {
        await _store.save(s);
        if (mounted) setState(() => _session = s);
      });
    }
    return HomePage(
      session: session,
      onSignOut: () async {
        await _store.clear();
        if (mounted) setState(() => _session = null);
      },
    );
  }
}

/// One form, one button: "Continue" signs in, or registers the account and
/// signs in when it does not exist yet.
class SignInPage extends StatefulWidget {
  const SignInPage({super.key, required this.onSignedIn});
  final Future<void> Function(Session) onSignedIn;

  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _auth = AuthClient(authUrl: kAuthUrl, apiKey: kFirebaseApiKey);
  String? _error;
  bool _busy = false;

  Future<void> _continue() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session = await _auth.continueWith(_email.text.trim(), _password.text);
      await widget.onSignedIn(session);
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Continue with email')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          key: const Key('auth_page'),
          children: [
            TextField(
              key: const Key('email_field'),
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Email'),
            ),
            TextField(
              key: const Key('password_field'),
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password'),
            ),
            const SizedBox(height: 16),
            if (_error != null)
              Text(
                _error!,
                key: const Key('sign_in_error'),
                style: const TextStyle(color: Colors.red),
              ),
            FilledButton(
              key: const Key('continue_button'),
              onPressed: _busy ? null : _continue,
              child: _busy
                  ? const SizedBox(
                      key: Key('auth_progress'),
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Continue'),
            ),
            const SizedBox(height: 8),
            const Text(
              'New email? An account is created for you.',
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.session, required this.onSignOut});
  final Session session;
  final Future<void> Function() onSignOut;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final ApiClient _api = ApiClient(kBackendUrl, widget.session);
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.session.email,
          key: const Key('signed_in_as'),
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          IconButton(
            key: const Key('sign_out_button'),
            icon: const Icon(Icons.logout),
            onPressed: widget.onSignOut,
          ),
        ],
      ),
      body: Column(
        children: [
          // How we got here — 'registered' / 'signed-in' / 'restored'. Lets
          // a test assert which auth path the app took.
          Container(
            key: const Key('auth_mode_banner'),
            width: double.infinity,
            color: Colors.green.shade50,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(
              switch (widget.session.mode) {
                'registered' => 'Account created — welcome!',
                'signed-in' => 'Welcome back!',
                _ => 'Session restored',
              },
              key: Key('auth_mode_${widget.session.mode}'),
              style: const TextStyle(fontSize: 12),
            ),
          ),
          Expanded(
            child: IndexedStack(
              index: _tab,
              children: [
                NotesView(api: _api),
                ChatView(api: _api),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
            key: Key('notes_tab'),
            icon: Icon(Icons.note),
            label: 'Notes',
          ),
          NavigationDestination(
            key: Key('chat_tab'),
            icon: Icon(Icons.chat),
            label: 'Chat',
          ),
        ],
      ),
    );
  }
}

/// Polls the backend on a timer; rebuilds only when data changes so tests
/// can find a frame-quiet state. Same wait-for-state pattern as ChatView.
class NotesView extends StatefulWidget {
  const NotesView({super.key, required this.api});
  final ApiClient api;

  @override
  State<NotesView> createState() => _NotesViewState();
}

class _NotesViewState extends State<NotesView> {
  final _text = TextEditingController();
  List<Map<String, dynamic>> _notes = const [];
  bool _loaded = false;
  String? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _refresh();
    _poll = Timer.periodic(const Duration(milliseconds: 500), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final notes = await widget.api.notes();
      if (!mounted) return;
      final changed = !_loaded ||
          notes.length != _notes.length ||
          _error != null ||
          !_sameIds(notes, _notes);
      if (changed) {
        setState(() {
          _notes = notes;
          _loaded = true;
          _error = null;
        });
      }
    } on Object catch (e) {
      if (mounted && _error == null) setState(() => _error = '$e');
    }
  }

  Future<void> _add() async {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    try {
      await widget.api.addNote(text);
      _text.clear();
      await _refresh();
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (_error != null) ErrorBanner(_error!),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('note_field'),
                  controller: _text,
                  decoration: const InputDecoration(hintText: 'New note'),
                ),
              ),
              IconButton(
                key: const Key('add_note_button'),
                icon: const Icon(Icons.add),
                onPressed: _add,
              ),
            ],
          ),
        ),
        Expanded(
          child: _loaded && _notes.isEmpty
              ? const Center(
                  child: Text('No notes yet', key: Key('notes_empty')),
                )
              : ListView(
                  key: const Key('notes_list'),
                  children: [
                    for (final n in _notes)
                      ListTile(
                        key: Key('note_${n['id']}'),
                        title: Text('${n['text']}'),
                        subtitle: Text(
                          n['seeded'] == true ? 'seeded' : '${n['createdAt']}',
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class ChatView extends StatefulWidget {
  const ChatView({super.key, required this.api});
  final ApiClient api;

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final _partner = TextEditingController();
  final _text = TextEditingController();
  String? _openWith;
  List<Map<String, dynamic>> _messages = const [];
  String? _error;
  Timer? _poll;

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _open() {
    final partner = _partner.text.trim();
    if (partner.isEmpty) return;
    _poll?.cancel();
    setState(() {
      _openWith = partner;
      _messages = const [];
      _error = null;
    });
    _refresh();
    _poll = Timer.periodic(const Duration(milliseconds: 500), (_) => _refresh());
  }

  Future<void> _refresh() async {
    final partner = _openWith;
    if (partner == null) return;
    try {
      final messages = await widget.api.messages(partner);
      if (!mounted) return;
      if (messages.length != _messages.length ||
          _error != null ||
          !_sameIds(messages, _messages)) {
        setState(() {
          _messages = messages;
          _error = null;
        });
      }
    } on Object catch (e) {
      if (mounted && _error == null) setState(() => _error = '$e');
    }
  }

  Future<void> _send() async {
    final partner = _openWith;
    final text = _text.text.trim();
    if (partner == null || text.isEmpty) return;
    try {
      await widget.api.sendMessage(partner, text);
      _text.clear();
      await _refresh();
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final partner = _openWith;
    return Column(
      children: [
        if (_error != null) ErrorBanner(_error!),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('partner_field'),
                  controller: _partner,
                  autocorrect: false,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(hintText: 'Chat with (email)'),
                ),
              ),
              IconButton(
                key: const Key('open_chat_button'),
                icon: const Icon(Icons.forum),
                onPressed: _open,
              ),
            ],
          ),
        ),
        if (partner != null) ...[
          Text('Chat with $partner', key: const Key('chat_header')),
          Expanded(
            child: ListView(
              key: const Key('message_list'),
              children: [
                for (final m in _messages)
                  ListTile(
                    key: Key('message_${m['id']}'),
                    dense: true,
                    leading: Text(m['from'] == widget.api.session.email ? 'me' : 'them'),
                    title: Text('${m['text']}'),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('message_field'),
                    controller: _text,
                    decoration: const InputDecoration(hintText: 'Message'),
                  ),
                ),
                IconButton(
                  key: const Key('send_message_button'),
                  icon: const Icon(Icons.send),
                  onPressed: _send,
                ),
              ],
            ),
          ),
        ] else
          const Expanded(child: SizedBox()),
      ],
    );
  }
}

class ErrorBanner extends StatelessWidget {
  const ErrorBanner(this.message, {super.key});
  final String message;

  @override
  Widget build(BuildContext context) => Container(
        key: const Key('error_banner'),
        color: Colors.red.shade100,
        padding: const EdgeInsets.all(8),
        width: double.infinity,
        child: Text(message, maxLines: 3),
      );
}

bool _sameIds(List<Map<String, dynamic>> a, List<Map<String, dynamic>> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i]['id'] != b[i]['id']) return false;
  }
  return true;
}
