import 'dart:async';
import 'dart:convert';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'config.dart';

// The scheme this demo app registers (ios/Runner/Info.plist CFBundleURLTypes).
const appScheme = 'fedemo';

void main() => runApp(const DemoApp());

class DemoApp extends StatelessWidget {
  const DemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'UAE Pass demo',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF0E7B4A), useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final List<String> _log = [];
  final _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSub;

  WebViewController? _webview;
  String? _pollToken;
  String? _savedSuccessUrl;
  String? _savedFailureUrl;
  Map<String, dynamic>? _profile;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Doc step 7→8: UAE Pass app re-opens us via fedemo:///resume_authn?url=<S>
    _linkSub = _appLinks.uriLinkStream.listen(_onAppLink);
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    super.dispose();
  }

  void _say(String line) {
    setState(() => _log.add(line));
    debugPrint('[demo] $line');
  }

  // ---- Step A: get oAuthUrl from Fill Easy -------------------------------

  Future<void> _startLogin() async {
    setState(() {
      _log.clear();
      _profile = null;
      _busy = true;
    });
    try {
      _say('POST $apiBase/uaepass/request/auth  source=iOS');
      final res = await http.post(
        Uri.parse('$apiBase/uaepass/request/auth'),
        headers: {
          'x-client-id': clientId,
          'x-client-secret': clientSecret,
          'content-type': 'application/json',
        },
        body: jsonEncode({'redirect': redirectUrl, 'lang': 'en', 'source': 'iOS'}),
      );
      if (res.statusCode != 200) {
        _say('request/auth failed: ${res.statusCode} ${res.body}');
        return;
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      _pollToken = body['token'] as String;
      final oAuthUrl = body['oAuthUrl'] as String;
      _say('got oAuthUrl → loading in EMBEDDED webview (doc step 2)');
      _openWebview(oAuthUrl);
    } finally {
      setState(() => _busy = false);
    }
  }

  // ---- Step B: embedded webview with interception (doc steps 2 & 4) ------

  String _short(String url) => url.length > 70 ? '${url.substring(0, 70)}…' : url;

  void _openWebview(String url) {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: _onNavigation,
        onPageStarted: (u) => _say('page started: ${_short(u)}'),
        onPageFinished: (u) => _say('page finished: ${_short(u)}'),
        onUrlChange: (c) => _say('url → ${_short(c.url ?? '?')}'),
        onHttpError: (e) =>
            _say('http error ${e.response?.statusCode} at ${_short(e.request?.uri.toString() ?? '?')}'),
        onWebResourceError: (e) =>
            _say('web error ${e.errorCode} (${e.errorType}): ${e.description}'),
      ))
      ..loadRequest(Uri.parse(url));
    _webview = controller;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('UAE PASS login')),
          body: WebViewWidget(controller: controller),
        ),
      ),
    );
  }

  FutureOr<NavigationDecision> _onNavigation(NavigationRequest req) {
    final url = req.url;

    // Doc step 4: "Monitor the webview for UAEPASS deep linking url".
    // Staging emits the PRODUCTION scheme uaepass:// — intercept both.
    if (url.startsWith('uaepass://') || url.startsWith('uaepassstg://')) {
      _say('intercepted deep link (doc step 4):');
      _say('  ${url.length > 90 ? '${url.substring(0, 90)}…' : url}');
      _rewriteAndLaunch(url);
      return NavigationDecision.prevent;
    }

    // Flow finished: Fill Easy's callback redirected to our `redirect`.
    if (url.startsWith(redirectUrl)) {
      _say('webview reached redirect → closing, polling for profile');
      Navigator.of(context).popUntil((r) => r.isFirst);
      _poll();
      return NavigationDecision.prevent;
    }

    return NavigationDecision.navigate;
  }

  // ---- Steps 5–7: save, rewrite, open the UAE Pass app -------------------

  Future<void> _rewriteAndLaunch(String deepLink) async {
    final original = Uri.parse(deepLink);

    // Doc step 5: save successurl / failureurl in variables.
    _savedSuccessUrl = original.queryParameters['successurl'];
    _savedFailureUrl = original.queryParameters['failureurl'];
    if (_savedSuccessUrl == null) {
      _say('deep link had no successurl — aborting');
      return;
    }
    _say('saved successurl/failureurl (doc step 5)');

    // Doc step 6: re-write the deep link.
    //  swap 1 — scheme: uaepass:// → uaepassstg:// (staging only)
    //  swap 2 — callbacks → our own app scheme
    final rewritten = original.replace(
      scheme: uaePassScheme, // 'uaepassstg' on staging, 'uaepass' on prod
      queryParameters: {
        ...original.queryParameters,
        'successurl': '$appScheme:///resume_authn?url=${Uri.encodeComponent(_savedSuccessUrl!)}',
        'failureurl': '$appScheme:///resume_authn?url=${Uri.encodeComponent(_savedFailureUrl ?? '')}',
      },
    );
    _say('rewritten (doc step 6): scheme=${rewritten.scheme}');

    // Doc step 7: open the UAE Pass app.
    final ok = await launchUrl(rewritten, mode: LaunchMode.externalApplication);
    _say(ok
        ? 'UAE Pass STAGING app opened (doc step 7)'
        : 'launch failed — is the staging app installed?');
  }

  // ---- Step 8: UAE Pass app hands control back to us ---------------------

  void _onAppLink(Uri link) {
    if (link.scheme != appScheme) return;
    final resumed = link.queryParameters['url'];
    _say('re-opened via $appScheme:// (doc step 7 callback)');
    if (resumed == null || _webview == null) return;

    // Doc step 8: load the SAVED successurl in the SAME webview.
    _say('loading saved successurl in same webview (doc step 8)');
    _webview!.loadRequest(Uri.parse(resumed));
  }

  // ---- Step C: poll Fill Easy for the profile ----------------------------

  Future<void> _poll() async {
    for (var attempt = 1; attempt <= 10; attempt++) {
      final res = await http.post(
        Uri.parse('$apiBase/uaepass/poll'),
        headers: {
          'x-client-id': clientId,
          'x-client-secret': clientSecret,
          'content-type': 'application/json',
        },
        body: jsonEncode({'token': _pollToken}),
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        _say('poll → 200, profile received');
        setState(() => _profile = data['data'] as Map<String, dynamic>?);
        return;
      }
      if (res.statusCode == 202) {
        _say('poll → 202 pending ($attempt/10)');
        await Future.delayed(const Duration(seconds: 2));
        continue;
      }
      _say('poll → ${res.statusCode} ${res.body}');
      return;
    }
    _say('poll timed out');
  }

  // ---- UI ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Fill Easy · UAE Pass demo')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton.icon(
              onPressed: _busy ? null : _startLogin,
              icon: const Icon(Icons.fingerprint),
              label: const Text('Login with UAE PASS (staging)'),
            ),
          ),
          if (_profile != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    const JsonEncoder.withIndent('  ').convert(_profile),
                    style: const TextStyle(fontFamily: 'Menlo', fontSize: 12),
                  ),
                ),
              ),
            ),
          const Divider(),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _log.length,
              itemBuilder: (_, i) => Text(
                _log[i],
                style: const TextStyle(fontFamily: 'Menlo', fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
