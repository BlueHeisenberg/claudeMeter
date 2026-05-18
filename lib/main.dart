import 'dart:async';
import 'dart:math' as math;

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'api.dart';
import 'auth.dart';
import 'login_page.dart';
import 'mascot.dart';
import 'verbs.dart';

// "serif" maps to Noto Serif / Droid Serif on Android, Times on iOS,
// and the platform serif on web — close enough to the Lora-style look
// without runtime font fetching.
TextStyle _serif({
  double? fontSize,
  FontWeight? fontWeight,
  Color? color,
  FontStyle? fontStyle,
  double? height,
}) {
  return TextStyle(
    fontFamily: 'serif',
    fontSize: fontSize,
    fontWeight: fontWeight,
    color: color,
    fontStyle: fontStyle,
    height: height,
  );
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  await WakelockPlus.enable();
  final store = AuthStore();
  await store.load();
  runApp(ClaudeMeterApp(store: store));
}

const _bg = Color(0xFF0A0A0A);
const _cardBg = Color(0xFF1A0F1A);
const _trackPurple = Color(0xFF4A2C5A);
const _pillPurple = Color(0xFF5D2E6E);
const _orange = Color(0xFFE85A3D);
const _lime = Color(0xFFCFE36B);
const _textDim = Color(0xFFB8A8C4);

class ClaudeMeterApp extends StatelessWidget {
  final AuthStore store;
  const ClaudeMeterApp({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Claude Meter',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: _bg,
        fontFamily: 'serif',
      ),
      home: _AuthGate(store: store),
    );
  }
}

class _AuthGate extends StatefulWidget {
  final AuthStore store;
  const _AuthGate({required this.store});
  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  @override
  void initState() {
    super.initState();
    widget.store.addListener(_rebuild);
  }

  @override
  void dispose() {
    widget.store.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() => setState(() {});

  @override
  Widget build(BuildContext context) {
    if (widget.store.isAuthenticated) {
      return UsagePage(store: widget.store);
    }
    return LoginPage(store: widget.store, onLoggedIn: _rebuild);
  }
}

class UsagePage extends StatefulWidget {
  final AuthStore store;
  const UsagePage({super.key, required this.store});

  @override
  State<UsagePage> createState() => _UsagePageState();
}

class _UsagePageState extends State<UsagePage> with TickerProviderStateMixin {
  late final UsageApi _api = UsageApi(widget.store);
  final _battery = Battery();
  Usage? _usage;
  String? _error;
  bool _loading = false;
  Timer? _poll;
  Timer? _tick;
  Timer? _batteryPoll;
  Timer? _verbCycle;
  int? _batteryLevel;
  bool _batteryCharging = false;
  late final AnimationController _statusBlink;

  final _rng = math.Random();
  String _verb = 'Brewing';
  DateTime? _rateLimitedUntil;
  int _consecutive429s = 0;
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;
  late final _LifecycleObserver _lifecycleObserver = _LifecycleObserver(
    onChange: (s) {
      _lifecycle = s;
      // Refetch on coming back to the foreground if the last fetch is stale.
      if (s == AppLifecycleState.resumed && _usage != null) {
        final age = DateTime.now().difference(_usage!.fetchedAt);
        if (age > const Duration(minutes: 10)) _load();
      }
    },
  );

  static const _backoffKey = 'cm_rate_limited_until_ms';
  static const _consecutiveKey = 'cm_consecutive_429s';
  static const List<int> _backoffMinutes = [30, 60, 120];

  @override
  void initState() {
    super.initState();
    _statusBlink = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
    _verb = _randomVerb();
    _restoreBackoff().then((_) => _load());
    _readBattery();
    _poll = Timer.periodic(const Duration(minutes: 10), (_) {
      if (_lifecycle == AppLifecycleState.resumed) _load();
    });
    WidgetsBinding.instance.addObserver(_lifecycleObserver);
    _batteryPoll = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _readBattery(),
    );
    _verbCycle = Timer.periodic(const Duration(milliseconds: 600), (_) {
      if (!mounted || !_loading) return;
      setState(() => _verb = _randomVerb());
    });
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  String _randomVerb() => kThinkingVerbs[_rng.nextInt(kThinkingVerbs.length)];

  Future<void> _restoreBackoff() async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(_backoffKey);
    final consec = prefs.getInt(_consecutiveKey) ?? 0;
    if (ms != null) {
      final t = DateTime.fromMillisecondsSinceEpoch(ms);
      if (t.isAfter(DateTime.now())) {
        if (mounted) {
          setState(() {
            _rateLimitedUntil = t;
            _consecutive429s = consec;
          });
        }
        return;
      } else {
        await prefs.remove(_backoffKey);
        await prefs.remove(_consecutiveKey);
      }
    }
  }

  Future<void> _persistBackoff(DateTime until, int consec) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_backoffKey, until.millisecondsSinceEpoch);
    await prefs.setInt(_consecutiveKey, consec);
  }

  Future<void> _clearBackoff() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_backoffKey);
    await prefs.remove(_consecutiveKey);
  }

  Future<void> _readBattery() async {
    try {
      final lvl = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      if (!mounted) return;
      setState(() {
        _batteryLevel = lvl;
        _batteryCharging = state == BatteryState.charging ||
            state == BatteryState.full;
      });
    } catch (_) {
      // Some platforms (e.g., web) don't expose the battery API; ignore.
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _tick?.cancel();
    _batteryPoll?.cancel();
    _verbCycle?.cancel();
    WidgetsBinding.instance.removeObserver(_lifecycleObserver);
    _statusBlink.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_rateLimitedUntil != null &&
        DateTime.now().isBefore(_rateLimitedUntil!)) {
      return;
    }
    setState(() {
      _loading = true;
      _verb = _randomVerb();
    });
    try {
      final u = await _api.fetch();
      if (!mounted) return;
      setState(() {
        _usage = u;
        _error = null;
        _rateLimitedUntil = null;
        _consecutive429s = 0;
        _loading = false;
      });
      _clearBackoff();
    } on RateLimitedException catch (_) {
      if (!mounted) return;
      final idx = _consecutive429s.clamp(0, _backoffMinutes.length - 1);
      final mins = _backoffMinutes[idx];
      final until = DateTime.now().add(Duration(minutes: mins));
      setState(() {
        _rateLimitedUntil = until;
        _consecutive429s = _consecutive429s + 1;
        _loading = false;
      });
      _persistBackoff(until, _consecutive429s);
    } on NotAuthenticatedException catch (_) {
      // AuthStore.clear() already fired notifyListeners — the gate will swap
      // us out for the login page. Nothing to render here.
      if (!mounted) return;
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: LayoutBuilder(builder: (context, c) {
        final landscape = c.maxWidth > c.maxHeight;
        return Padding(
          padding: const EdgeInsets.fromLTRB(28, 16, 28, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(),
              const SizedBox(height: 14),
              Expanded(
                child: _error != null
                    ? Center(child: _errorView())
                    : (landscape
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                child: _usageCard(
                                  label: 'Current',
                                  pool: _usage?.fiveHour,
                                  fill: _orange,
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: _usageCard(
                                  label: 'Weekly',
                                  pool: _usage?.sevenDay,
                                  fill: _lime,
                                ),
                              ),
                            ],
                          )
                        : Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _usageCard(
                                label: 'Current',
                                pool: _usage?.fiveHour,
                                fill: _orange,
                              ),
                              const SizedBox(height: 14),
                              _usageCard(
                                label: 'Weekly',
                                pool: _usage?.sevenDay,
                                fill: _lime,
                              ),
                            ],
                          )),
              ),
              const SizedBox(height: 8),
              _statusLine(),
            ],
          ),
        );
      }),
    );
  }

  Widget _header() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        GestureDetector(
          onLongPress: _confirmLogout,
          child: ClaudeMascot(size: 44, animate: _loading),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Text(
            'Usage',
            textAlign: TextAlign.center,
            style: _serif(
              fontSize: 38,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ),
        GestureDetector(
          onTap: () {
            _load();
            _readBattery();
          },
          child: _batteryLevel == null
              ? const SizedBox.shrink()
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${_batteryLevel!}%',
                      style: _serif(
                        fontSize: 14,
                        color: Colors.white,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(width: 6),
                    if (_batteryCharging) ...[
                      SizedBox(
                        width: 12,
                        height: 22,
                        child: CustomPaint(painter: _BoltPainter()),
                      ),
                      const SizedBox(width: 10),
                    ],
                    SizedBox(
                      width: 44,
                      height: 22,
                      child: CustomPaint(
                        painter: _BatteryPainter(
                          level: _batteryLevel! / 100,
                          charging: _batteryCharging,
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _usageCard({
    required String label,
    required UsagePool? pool,
    required Color fill,
  }) {
    final pct = pool == null ? 0.0 : pool.utilization.clamp(0.0, 100.0);
    final pctStr = pool == null ? '--' : '${pct.toStringAsFixed(0)}%';
    final resetText = pool?.resetsAt == null
        ? 'Resets in —'
        : 'Resets in ${_formatRemaining(pool!.resetsAt!)}';

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                pctStr,
                style: _serif(
                  fontSize: 34,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  height: 1.0,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: _pillPurple,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  label,
                  style: _serif(
                    fontSize: 15,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _bar(pct / 100, fill),
          const SizedBox(height: 8),
          Text(
            resetText,
            style: _serif(
              fontSize: 15,
              color: _textDim,
            ),
          ),
        ],
      ),
    );
  }

  Widget _bar(double fraction, Color fill) {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      return Container(
        height: 16,
        decoration: BoxDecoration(
          color: _trackPurple,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 600),
            curve: Curves.easeOutCubic,
            width: math.max(0, w * fraction.clamp(0.0, 1.0)),
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
      );
    });
  }

  Widget _statusLine() {
    if (_rateLimitedUntil != null &&
        DateTime.now().isBefore(_rateLimitedUntil!)) {
      return Center(
        child: Text(
          '* Rate limited — retry in ${_formatRemaining(_rateLimitedUntil!)}',
          style: _serif(
            fontSize: 16,
            color: _lime,
            fontStyle: FontStyle.italic,
          ),
        ),
      );
    }
    if (_loading) {
      return FadeTransition(
        opacity: _statusBlink,
        child: Center(
          child: Text(
            '* $_verb…',
            style: _serif(
              fontSize: 18,
              color: _orange,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      );
    }
    final ago = _usage == null
        ? '—'
        : _ago(DateTime.now().difference(_usage!.fetchedAt));
    return Center(
      child: Text(
        'Updated $ago',
        style: _serif(fontSize: 13, color: _textDim),
      ),
    );
  }

  String _ago(Duration d) {
    if (d.inSeconds < 30) return 'just now';
    if (d.inMinutes < 1) return '${d.inSeconds}s ago';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    return '${d.inHours}h ago';
  }

  Future<void> _confirmLogout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _cardBg,
        title: const Text(
          'Log out?',
          style: TextStyle(color: Colors.white, fontFamily: 'serif'),
        ),
        content: const Text(
          'You will need to sign in again to see your usage.',
          style: TextStyle(color: _textDim, fontFamily: 'serif'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: _textDim)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Log out', style: TextStyle(color: _orange)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.store.clear();
    }
  }

  Widget _errorView() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _orange, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Could not fetch usage',
            style: _serif(
              fontSize: 18,
              color: _orange,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _error ?? '',
            style: _serif(fontSize: 13, color: _textDim),
          ),
          const SizedBox(height: 10),
          TextButton(
            onPressed: _load,
            style: TextButton.styleFrom(foregroundColor: _orange),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  String _formatRemaining(DateTime target) {
    final diff = target.difference(DateTime.now());
    if (diff.isNegative) return '0m';
    final d = diff.inDays;
    final h = diff.inHours.remainder(24);
    final m = diff.inMinutes.remainder(60);
    if (d > 0) return '${d}d ${h}h';
    if (h > 0) return '${h}h ${m}m';
    return '${m}m';
  }
}

class _BatteryPainter extends CustomPainter {
  final double level;
  final bool charging;

  _BatteryPainter({required this.level, required this.charging});

  @override
  void paint(Canvas canvas, Size size) {
    final lv = level.clamp(0.0, 1.0);
    final fillColor = charging
        ? const Color(0xFFCFE36B)
        : (lv <= 0.15 ? const Color(0xFFE85A3D) : Colors.white);

    final stroke = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final solid = Paint()..color = fillColor;
    final nubPaint = Paint()..color = Colors.white;

    const nubWidth = 3.0;
    const padding = 4.0;
    final bodyW = size.width - nubWidth - 1;

    final body = Rect.fromLTWH(0, 0, bodyW, size.height);
    canvas.drawRRect(
      RRect.fromRectAndRadius(body, const Radius.circular(3)),
      stroke,
    );

    final innerW = bodyW - padding * 2;
    final innerH = size.height - padding * 2;
    final fillRect = Rect.fromLTWH(padding, padding, innerW * lv, innerH);
    canvas.drawRRect(
      RRect.fromRectAndRadius(fillRect, const Radius.circular(1)),
      solid,
    );

    final nub = Rect.fromLTWH(
      bodyW,
      size.height * 0.3,
      nubWidth,
      size.height * 0.4,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(nub, const Radius.circular(1)),
      nubPaint,
    );

  }

  @override
  bool shouldRepaint(_BatteryPainter old) =>
      old.level != level || old.charging != charging;
}

class _BoltPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0xFFCFE36B);
    final w = size.width;
    final h = size.height;
    final bolt = Path()
      ..moveTo(w * 0.55, 0)
      ..lineTo(0, h * 0.55)
      ..lineTo(w * 0.40, h * 0.55)
      ..lineTo(w * 0.30, h)
      ..lineTo(w, h * 0.40)
      ..lineTo(w * 0.55, h * 0.40)
      ..close();
    canvas.drawPath(bolt, paint);
  }

  @override
  bool shouldRepaint(_BoltPainter old) => false;
}

class _LifecycleObserver with WidgetsBindingObserver {
  final void Function(AppLifecycleState) onChange;
  _LifecycleObserver({required this.onChange});

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => onChange(state);
}
