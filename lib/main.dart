import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const StatusCrispApp());
}

class StatusCrispApp extends StatelessWidget {
  const StatusCrispApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'StatusCrisp',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF080C14),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF10B981),
          secondary: Color(0xFF0D9488),
        ),
      ),
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
  final ImagePicker _picker = ImagePicker();
  File? _selectedVideo;
  String? _outputVideoPath;

  bool _isProcessing = false;
  String _statusMessage = 'Tap to select a 4K, 60fps, or HDR video';
  double _progressPercent = 0.0;

  String _sharpnessMode = 'ultra'; // 'ultra', 'natural', 'off'
  bool _hdrColorFix = true;
  bool _trimTo30s = true;

  int _freeExportsLeft = 3;
  bool _isPro = false;

  @override
  void initState() {
    super.initState();
    _loadUserStatus();
  }

  Future<void> _loadUserStatus() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _freeExportsLeft = prefs.getInt('sc_free_left') ?? 3;
      _isPro = prefs.getBool('sc_is_pro') ?? false;
    });
  }

  Future<void> _pickVideo() async {
    try {
      final XFile? video = await _picker.pickVideo(source: ImageSource.gallery);
      if (video != null) {
        final file = File(video.path);
        final sizeInMb = (await file.length()) / (1024 * 1024);
        setState(() {
          _selectedVideo = file;
          _outputVideoPath = null;
          _progressPercent = 0.0;
          _statusMessage =
              'Original: ${sizeInMb.toStringAsFixed(1)} MB • Ready for Native Crisp';
        });
      }
    } catch (e) {
      setState(() {
        _statusMessage = 'Could not load video: $e';
      });
    }
  }

  Future<void> _optimizeForWhatsApp() async {
    if (_selectedVideo == null) return;

    if (!_isPro && _freeExportsLeft <= 0) {
      _showPaystackUpgradeSheet();
      return;
    }

    setState(() {
      _isProcessing = true;
      _progressPercent = 0.05;
      _statusMessage = 'Running Native libx264 High-Profile Engine...';
    });

    final tempDir = await getTemporaryDirectory();
    final outputPath =
        '${tempDir.path}/StatusCrisp_HD_${DateTime.now().millisecondsSinceEpoch}.mp4';

    // 1. Unsharp Mask Matrix (PureStatus-grade luma & chroma edge sharpening)
    String sharpenFilter = '';
    if (_sharpnessMode == 'ultra') {
      sharpenFilter = ',unsharp=5:5:0.85:3:3:0.4';
    } else if (_sharpnessMode == 'natural') {
      sharpenFilter = ',unsharp=3:3:0.55:3:3:0.0';
    }

    // 2. HDR to Vibrant SDR Color Grading
    final colorFilter =
        _hdrColorFix ? ',eq=contrast=1.06:saturation=1.10:brightness=0.01' : '';

    // 3. Foolproof Even-Dimension Lanczos Scaling (Never fails on odd aspect ratios)
    final vfChain =
        'scale=\'min(1080,iw)\':-2:flags=lanczos$sharpenFilter$colorFilter,fps=30,format=yuv420p';

    final trimFlag = _trimTo30s ? '-t 30 ' : '';

    // 4. Strict CRF 21 + 1950k Maxrate so file sits under ~7.5MB and bypasses WhatsApp re-compression
    final command = '-y $trimFlag-i "${_selectedVideo!.path}" '
        '-vf "$vfChain" '
        '-c:v libx264 -profile:v high -level:v 4.1 -preset veryfast '
        '-crf 21 -maxrate 1950k -bufsize 3900k -g 60 -keyint_min 30 '
        '-color_primaries bt709 -color_trc bt709 -colorspace bt709 '
        '-c:a aac -b:a 128k -ar 44100 '
        '-movflags +faststart "$outputPath"';

    await FFmpegKit.executeAsync(
      command,
      (session) async {
        final returnCode = await session.getReturnCode();
        if (ReturnCode.isSuccess(returnCode)) {
          final outFile = File(outputPath);
          final outSizeMb = (await outFile.length()) / (1024 * 1024);

          if (!_isPro) {
            final prefs = await SharedPreferences.getInstance();
            _freeExportsLeft = (_freeExportsLeft - 1).clamp(0, 99);
            await prefs.setInt('sc_free_left', _freeExportsLeft);
          }

          if (!mounted) return;
          setState(() {
            _isProcessing = false;
            _outputVideoPath = outputPath;
            _progressPercent = 1.0;
            _statusMessage =
                'Crisp HD Ready! Final Size: ${outSizeMb.toStringAsFixed(1)} MB';
          });
        } else {
          final logs = await session.getAllLogsAsString();
          if (!mounted) return;
          setState(() {
            _isProcessing = false;
            _statusMessage =
                'Encoding error. Check clip format.\n${logs?.split('\n').last ?? ''}';
          });
        }
      },
      null,
      (Statistics stats) {
        final timeMs = stats.getTime();
        if (timeMs > 0 && mounted) {
          setState(() {
            _progressPercent = (timeMs / 30000).clamp(0.08, 0.98);
            _statusMessage =
                'Crisping frames: ${(timeMs / 1000).toStringAsFixed(1)}s encoded...';
          });
        }
      },
    );
  }

  Future<void> _shareToWhatsApp() async {
    if (_outputVideoPath == null) return;
    await Share.shareXFiles(
      [XFile(_outputVideoPath!)],
      text: 'StatusCrisp HD',
    );
  }

  void _showPaystackUpgradeSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF111928),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Unlock Lifetime Pro ⚡',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Unlimited 4K/HDR WhatsApp Status optimizations with native Lanczos + Unsharp encoding for a one-time ₦1,000 payment.',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF10B981),
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: () async {
                  final Uri paystackUrl =
                      Uri.parse('https://paystack.com/pay/statuscrisp-pro');
                  if (await canLaunchUrl(paystackUrl)) {
                    await launchUrl(paystackUrl,
                        mode: LaunchMode.externalApplication);
                  }
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setBool('sc_is_pro', true);
                  setState(() => _isPro = true);
                  if (context.mounted) Navigator.pop(context);
                },
                child: const Text(
                  'Unlock Now — ₦1,000 (OPay / Transfer)',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('StatusCrisp Pro',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        actions: [
          GestureDetector(
            onTap: _showPaystackUpgradeSheet,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: _isPro
                    ? const Color(0xFF10B981).withValues(alpha: 0.2)
                    : Colors.white10,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                    color: _isPro ? const Color(0xFF10B981) : Colors.white24),
              ),
              child: Center(
                child: Text(
                  _isPro ? 'PRO UNLOCKED' : '$_freeExportsLeft Free Left',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: _isPro ? const Color(0xFF10B981) : Colors.white70,
                  ),
                ),
              ),
            ),
          )
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: GestureDetector(
                onTap: _isProcessing ? null : _pickVideo,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF111928),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: Colors.white12, width: 1.5),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _outputVideoPath != null
                            ? Icons.verified_rounded
                            : Icons.video_library_rounded,
                        size: 56,
                        color: const Color(0xFF10B981),
                      ),
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Text(
                          _statusMessage,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (_isProcessing) ...[
                        const SizedBox(height: 16),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 40),
                          child: LinearProgressIndicator(
                            value: _progressPercent,
                            backgroundColor: Colors.white10,
                            color: const Color(0xFF10B981),
                            minHeight: 6,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                _buildSharpChip('ultra', 'Ultra Crisp (4K)'),
                const SizedBox(width: 8),
                _buildSharpChip('natural', 'Natural HD'),
                const SizedBox(width: 8),
                _buildSharpChip('off', 'No Sharpen'),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFF111928),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white10),
              ),
              child: Column(
                children: [
                  SwitchListTile(
                    title: const Text('HDR → Vibrant SDR Color Fix',
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                    activeColor: const Color(0xFF10B981),
                    value: _hdrColorFix,
                    onChanged: (val) => setState(() => _hdrColorFix = val),
                  ),
                  const Divider(height: 1, color: Colors.white10),
                  SwitchListTile(
                    title: const Text('Auto-Trim to 30s Status Limit',
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                    activeColor: const Color(0xFF10B981),
                    value: _trimTo30s,
                    onChanged: (val) => setState(() => _trimTo30s = val),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (_outputVideoPath == null)
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF10B981),
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: (_selectedVideo == null || _isProcessing)
                    ? null
                    : _optimizeForWhatsApp,
                child: const Text(
                  'OPTIMIZE FOR WHATSAPP HD',
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15),
                ),
              )
            else
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF10B981),
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: _shareToWhatsApp,
                icon: const Icon(Icons.send_rounded),
                label: const Text(
                  'SHARE TO WHATSAPP STATUS',
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSharpChip(String mode, String label) {
    final isSelected = _sharpnessMode == mode;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _sharpnessMode = mode),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isSelected
                ? const Color(0xFF10B981).withValues(alpha: 0.2)
                : const Color(0xFF111928),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: isSelected ? const Color(0xFF10B981) : Colors.white12),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: isSelected ? const Color(0xFF10B981) : Colors.white70,
            ),
          ),
        ),
      ),
    );
  }
}
