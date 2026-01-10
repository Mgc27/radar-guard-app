import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:vibration/vibration.dart';

const String baseUrl = String.fromEnvironment('BASE_URL', defaultValue: 'http://192.168.40.16:8000');
const String apiKey = String.fromEnvironment('API_KEY', defaultValue: 'devkey-123');

// Debug: forzar blink cuando color sea rojo (solo UI)
const bool forceBlinkOnRed = true;

// Driver settings
const int userId = 3;
const double radiusKm = 5.0;

// Polling: cada cuánto llamamos al backend
const Duration apiPollEvery = Duration(seconds: 1);

// Location: configuración de GPS
const LocationSettings locationSettings = LocationSettings(
  accuracy: LocationAccuracy.bestForNavigation,
  distanceFilter: 2, // metros mínimos para emitir update
);

void main() {
  runApp(const RadarGuardApp());
}

class RadarGuardApp extends StatelessWidget {
  const RadarGuardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Radar Guard',
      debugShowCheckedModeBanner: false,
      home: const StatusScreen(),
    );
  }
}

class StatusScreen extends StatefulWidget {
  const StatusScreen({super.key});

  @override
  State<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends State<StatusScreen> {
  Map<String, dynamic>? data;
  String? error;

  // --- Timers / streams ---
  Timer? _apiTimer;
  Timer? _blinkTimer;
  Timer? _beepTimer;
  Timer? _vibeTimer;
  StreamSubscription<Position>? _posSub;

  bool _blinkOn = true;
  bool _inFlight = false;

  DateTime? _lastUpdate;
  int _fetchCount = 0;
  bool _pulse = false;

  // --- Location state ---
  Position? _lastPos;
  DateTime? _lastPosAt;
  double? _computedHeadingDeg;

  // Audio
  final AudioPlayer _player = AudioPlayer();
  bool _audioReady = false;

  // Para no recrear timers si el patrón no cambió
  String _lastBeepPattern = '';
  String _lastVibePattern = '';

  // -------- Derived from backend response --------
  String get apiColor => (data?['color'] ?? '').toString();
  bool get uiBlinkFromBackend => data?['ui_blink'] == true;

  bool get shouldBlink {
    final forced = forceBlinkOnRed && apiColor == 'red';
    return uiBlinkFromBackend || forced;
  }

  String get beepPattern =>
      (data?['beep_pattern'] ?? '').toString().trim().toLowerCase();

  // -------------------- AUDIO --------------------

  Future<void> _initAudioOnce() async {
    if (_audioReady) return;
    await _player.setReleaseMode(ReleaseMode.stop);
    _audioReady = true;
  }

  Future<void> _playBeepOnce() async {
    await _initAudioOnce();
    await _player.play(
      AssetSource('sounds/beep.mp3'),
      volume: 1.0,
    );
  }

  void _cancelBeepTimer() {
    _beepTimer?.cancel();
    _beepTimer = null;
  }

  void _syncBeepTimer() {
    final pattern = beepPattern;

    if (pattern == _lastBeepPattern) return;
    _lastBeepPattern = pattern;

    _cancelBeepTimer();

    if (pattern.isEmpty ||
        pattern == 'none' ||
        pattern == 'off' ||
        pattern == 'silent') {
      return;
    }

    // urgent: triple cada 1.5s
    if (pattern == 'urgent') {
      _beepTimer =
          Timer.periodic(const Duration(milliseconds: 1500), (_) async {
        if (!mounted) return;
        await _playBeepOnce();
        await Future.delayed(const Duration(milliseconds: 160));
        if (!mounted) return;
        await _playBeepOnce();
        await Future.delayed(const Duration(milliseconds: 160));
        if (!mounted) return;
        await _playBeepOnce();
      });
      return;
    }

    Duration? every;
    if (pattern == 'slow') {
      every = const Duration(seconds: 2);
    } else if (pattern == 'medium') {
      every = const Duration(seconds: 1);
    } else if (pattern == 'fast') {
      every = const Duration(milliseconds: 500);
    }

    if (every != null) {
      _beepTimer = Timer.periodic(every, (_) {
        if (!mounted) return;
        _playBeepOnce();
      });
      return;
    }

    if (pattern == 'triple') {
      _beepTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
        if (!mounted) return;
        await _playBeepOnce();
        await Future.delayed(const Duration(milliseconds: 180));
        if (!mounted) return;
        await _playBeepOnce();
        await Future.delayed(const Duration(milliseconds: 180));
        if (!mounted) return;
        await _playBeepOnce();
      });
      return;
    }

    _beepTimer = Timer.periodic(const Duration(milliseconds: 600), (_) {
      if (!mounted) return;
      _playBeepOnce();
    });
  }

  // -------------------- VIBRACIÓN --------------------

  void _cancelVibeTimer() {
    _vibeTimer?.cancel();
    _vibeTimer = null;
  }

  Future<void> _vibrateOnce({int durationMs = 120}) async {
    final hasVibrator = await Vibration.hasVibrator() ?? false;
    if (!hasVibrator) return;
    await Vibration.vibrate(duration: durationMs);
  }

  void _syncVibration() {
    final pattern = beepPattern;

    if (pattern == _lastVibePattern) return;
    _lastVibePattern = pattern;

    _cancelVibeTimer();

    if (pattern != 'urgent') return;

    _vibeTimer =
        Timer.periodic(const Duration(milliseconds: 1500), (_) async {
      if (!mounted) return;
      await _vibrateOnce(durationMs: 120);
      await Future.delayed(const Duration(milliseconds: 160));
      if (!mounted) return;
      await _vibrateOnce(durationMs: 120);
      await Future.delayed(const Duration(milliseconds: 160));
      if (!mounted) return;
      await _vibrateOnce(durationMs: 120);
    });
  }

  // -------------------- BLINK --------------------

  void _syncBlinkTimer() {
    if (shouldBlink) {
      _blinkTimer ??= Timer.periodic(const Duration(milliseconds: 350), (_) {
        if (!mounted) return;
        setState(() => _blinkOn = !_blinkOn);
      });
    } else {
      _blinkTimer?.cancel();
      _blinkTimer = null;
      if (_blinkOn == false) {
        setState(() => _blinkOn = true);
      }
    }
  }

  Color backgroundColor() {
    if (shouldBlink && !_blinkOn) return Colors.black;

    switch (apiColor) {
      case 'red':
        return Colors.red.shade700;
      case 'yellow':
      case 'orange':
        return Colors.orange.shade600;
      default:
        return Colors.green.shade700;
    }
  }

  // -------------------- LOCATION --------------------

  Future<bool> _ensureLocationReady() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() {
        error = 'Activa el GPS/servicios de ubicación del dispositivo.';
      });
      return false;
    }

    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }

    if (perm == LocationPermission.denied) {
      setState(() {
        error = 'Permiso de ubicación denegado.';
      });
      return false;
    }

    if (perm == LocationPermission.deniedForever) {
      setState(() {
        error =
            'Permiso de ubicación denegado permanentemente. Habilítalo en Ajustes.';
      });
      return false;
    }

    // OK
    return true;
  }

  void _startLocationStream() async {
    final ok = await _ensureLocationReady();
    if (!ok) return;

    _posSub?.cancel();
    _posSub = Geolocator.getPositionStream(locationSettings: locationSettings)
        .listen((pos) {
      final now = DateTime.now();

      // Calcula heading si el dispositivo no lo da (o viene 0)
      double? heading = pos.heading;
      if ((heading.isNaN) || (heading <= 0.1)) {
        heading = _estimateHeadingDeg(_lastPos, pos);
      }

      setState(() {
        _lastPos = pos;
        _lastPosAt = now;
        _computedHeadingDeg = heading;
        error = null; // limpia si ya tenemos GPS
      });
    }, onError: (e) {
      setState(() => error = 'GPS error: $e');
    });
  }

  double? _estimateHeadingDeg(Position? prev, Position curr) {
    if (prev == null) return null;
    // Si no se movió, no hay heading.
    final d = _haversineMeters(prev.latitude, prev.longitude, curr.latitude, curr.longitude);
    if (d < 2.0) return null;

    final y = sin(_deg2rad(curr.longitude - prev.longitude)) * cos(_deg2rad(curr.latitude));
    final x = cos(_deg2rad(prev.latitude)) * sin(_deg2rad(curr.latitude)) -
        sin(_deg2rad(prev.latitude)) *
            cos(_deg2rad(curr.latitude)) *
            cos(_deg2rad(curr.longitude - prev.longitude));
    var brng = atan2(y, x);
    brng = _rad2deg(brng);
    brng = (brng + 360) % 360;
    return brng;
  }

  double _haversineMeters(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371000.0;
    final dLat = _deg2rad(lat2 - lat1);
    final dLon = _deg2rad(lon2 - lon1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_deg2rad(lat1)) * cos(_deg2rad(lat2)) *
            sin(dLon / 2) * sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return r * c;
  }

  double _deg2rad(double d) => d * pi / 180.0;
  double _rad2deg(double r) => r * 180.0 / pi;

  // -------------------- API CALL --------------------

  Uri _buildStatusUriFromGps() {
    // si no hay GPS todavía, usa un default (para no reventar)
    final lat = _lastPos?.latitude ?? 4.64;
    final lng = _lastPos?.longitude ?? -74.08;

    // speed en m/s -> km/h
    final speedMs = _lastPos?.speed ?? 0.0;
    final speedKmh = max(0.0, speedMs * 3.6);

    // heading: si viene null, manda 0
    final headingDeg = _computedHeadingDeg ?? (_lastPos?.heading ?? 0.0);

    return Uri.parse(
      '$baseUrl/driver/status'
      '?lat=$lat&lng=$lng'
      '&speed_kmh=${speedKmh.toStringAsFixed(1)}'
      '&heading_deg=${headingDeg.toStringAsFixed(0)}'
      '&user_id=$userId'
      '&radius_km=$radiusKm',
    );
  }

  Future<void> fetchStatus() async {
    if (_inFlight) return;
    _inFlight = true;

    try {
      final uri = _buildStatusUriFromGps();

      final res = await http.get(
        uri,
        headers: {'X-API-Key': apiKey},
      );

      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body) as Map<String, dynamic>;

        setState(() {
          data = decoded;
          _lastUpdate = DateTime.now();
          _fetchCount++;
          _pulse = !_pulse;
        });

        _syncBlinkTimer();
        _syncBeepTimer();
        _syncVibration();
      } else {
        setState(() => error = 'HTTP ${res.statusCode}: ${res.body}');
      }
    } catch (e) {
      setState(() => error = 'Error: $e');
    } finally {
      _inFlight = false;
    }
  }

  // -------------------- LIFECYCLE --------------------

  @override
  void initState() {
    super.initState();
    _startLocationStream();

    // Poll API
    fetchStatus();
    _apiTimer = Timer.periodic(apiPollEvery, (_) => fetchStatus());
  }

  @override
  void dispose() {
    _apiTimer?.cancel();
    _blinkTimer?.cancel();
    _cancelBeepTimer();
    _cancelVibeTimer();
    _posSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  // -------------------- UI HELPERS --------------------

  String _safeStr(dynamic v) => (v ?? '').toString();

  double? _safeDouble(dynamic v) {
    if (v is num) return v.toDouble();
    return null;
  }

  String _formatTime(DateTime? dt) {
    if (dt == null) return '--:--:--';
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  // -------------------- BUILD --------------------

  @override
  Widget build(BuildContext context) {
    final nearest = data?['nearest_radar'] as Map<String, dynamic>?;
    final roadName = nearest?['road_name'];
    final speedLimit = nearest?['speed_limit_kmh'];

    final distKm = _safeDouble(data?['distance_to_radar_km']);
    final speedStatus = _safeStr(data?['speed_status']);
    final uiMessage = _safeStr(data?['ui_message']);

    final lat = _lastPos?.latitude;
    final lng = _lastPos?.longitude;
    final speedKmh = (_lastPos?.speed ?? 0.0) * 3.6;
    final heading = _computedHeadingDeg ?? _lastPos?.heading;

    return Scaffold(
      backgroundColor: backgroundColor(),
      appBar: AppBar(
        title: const Text('Radar Guard'),
        backgroundColor: Colors.black,
        actions: [
          IconButton(
            onPressed: () async {
              _startLocationStream();
              fetchStatus();
            },
            icon: const Icon(Icons.refresh),
            tooltip: 'Refrescar',
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Builder(
            builder: (_) {
              if (error != null && (data == null)) {
                return Text(
                  error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 16,
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                );
              }

              if (data == null) {
                return const CircularProgressIndicator(color: Colors.white);
              }

              return Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    _safeStr(roadName).isEmpty ? 'Radar cercano' : _safeStr(roadName),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 28,
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    distKm == null ? '-- km' : '${distKm.toStringAsFixed(2)} km',
                    style: const TextStyle(
                      fontSize: 22,
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Límite: ${_safeStr(speedLimit)} km/h',
                    style: const TextStyle(fontSize: 18, color: Colors.white),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Estado: $speedStatus',
                    style: const TextStyle(fontSize: 16, color: Colors.white70),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _pulse ? Colors.white : Colors.white38,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Actualizado: ${_formatTime(_lastUpdate)} • fetch #$_fetchCount',
                        style: const TextStyle(fontSize: 14, color: Colors.white70),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'beep_pattern: ${beepPattern.isEmpty ? "(vacío)" : beepPattern}',
                    style: const TextStyle(fontSize: 13, color: Colors.white70),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'GPS: ${lat?.toStringAsFixed(5) ?? "--"}, ${lng?.toStringAsFixed(5) ?? "--"}'
                    ' • ${speedKmh.toStringAsFixed(1)} km/h'
                    ' • heading ${heading == null ? "--" : heading.toStringAsFixed(0)}°',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 13, color: Colors.white70),
                  ),
                  if (uiMessage.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    Text(
                      uiMessage,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 18,
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  if (error != null) ...[
                    const SizedBox(height: 14),
                    Text(
                      error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 13, color: Colors.white70),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
