import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import '../models/download_item.dart';
import '../providers/download_provider.dart';
import '../providers/settings_provider.dart';
import '../services/download_service.dart';
import '../theme/app_theme.dart';
import '../widgets/platform_badge.dart';
import 'downloads_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  final _urlController = TextEditingController();
  final _focusNode = FocusNode();
  VideoQuality _selectedQuality = VideoQuality.best;
  SupportedPlatform _detectedPlatform = SupportedPlatform.generic;
  bool _urlValid = false;
  int _currentTab = 0;

  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;
  StreamSubscription? _intentSub;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.95, end: 1.05).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _urlController.addListener(_onUrlChanged);

    // Load default quality from settings
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final settings = context.read<SettingsProvider>();
      setState(() {
        _selectedQuality = settings.defaultQuality;
      });

      // Handle URL shared while app was already open (stream)
      _intentSub = ReceiveSharingIntent.instance.getMediaStream().listen(
        (items) => _handleSharedMedia(items),
        onError: (_) {},
      );

      // Handle URL that launched the app cold (one-shot).
      ReceiveSharingIntent.instance.getInitialMedia().then((items) {
        if (items.isNotEmpty) {
          _handleSharedMedia(items);
          ReceiveSharingIntent.instance.reset();
        }
      });
    });
  }

  /// Extracts the first http/https URL from [text], which may be a bare URL
  /// or a human-readable string like "Check this out https://instagram.com/reel/…".
  String? _extractUrl(String text) {
    // First try the whole trimmed string
    final trimmed = text.trim();
    if (isValidUrl(trimmed)) return trimmed;
    // Fall back: find first http(s) URL in the string
    final urlRegex = RegExp(
      r'https?://[^\s\u200B-\u200D\uFEFF]+',
      caseSensitive: false,
    );
    final match = urlRegex.firstMatch(text);
    if (match != null) {
      final candidate = match.group(0)!.replaceAll(RegExp(r'[.,;!?)]+$'), '');
      if (isValidUrl(candidate)) return candidate;
    }
    return null;
  }

  /// Processes a list of shared items — we only care about text/URL types.
  void _handleSharedMedia(List<SharedMediaFile> items) {
    for (final item in items) {
      // receive_sharing_intent puts the shared text in item.path for text/url types
      final text = item.path.trim();
      final url = _extractUrl(text);
      if (url != null) {
        _autoDownload(url);
        return; // one at a time
      }
    }
  }

  /// Shows the download options sheet, then starts the download on confirm.
  Future<void> _autoDownload(String url) async {
    if (!mounted) return;
    final defaultQuality = context.read<SettingsProvider>().defaultQuality;
    await _showDownloadSheet(url, defaultQuality);
  }

  Future<void> _showDownloadSheet(String url, VideoQuality initialQuality) async {
    if (!mounted) return;
    final result = await showModalBottomSheet<_DownloadOptions>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _DownloadOptionsSheet(
        url: url,
        initialQuality: initialQuality,
      ),
    );
    if (result == null || !mounted) return;
    context.read<DownloadProvider>().addDownload(result.url, result.quality);
    setState(() => _currentTab = 1);
  }

  void _onUrlChanged() {
    final url = _urlController.text.trim();
    final valid = isValidUrl(url);
    final platform = detectPlatform(url);
    setState(() {
      _urlValid = valid;
      _detectedPlatform = platform;
    });
  }

  @override
  void dispose() {
    _intentSub?.cancel();
    _urlController.dispose();
    _focusNode.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      _urlController.text = data.text!.trim();
      _urlController.selection = TextSelection.fromPosition(
        TextPosition(offset: _urlController.text.length),
      );
    }
  }

  void _startDownload() {
    final url = _urlController.text.trim();
    if (!isValidUrl(url)) return;
    _urlController.clear();
    setState(() {
      _urlValid = false;
      _detectedPlatform = SupportedPlatform.generic;
    });
    _showDownloadSheet(url, _selectedQuality);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentTab,
        children: [
          _buildHomeTab(),
          const DownloadsScreen(),
          const SettingsScreen(),
        ],
      ),
      bottomNavigationBar: _buildBottomBar(),
    );
  }

  Widget _buildBottomBar() {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surface,
        border: Border(
          top: BorderSide(
            color: Colors.white.withValues(alpha: 0.06),
            width: 1,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildNavItem(0, Icons.download_rounded, Icons.download_outlined, 'Download'),
              _buildNavItem(1, Icons.folder_rounded, Icons.folder_outlined, 'My Files'),
              _buildNavItem(2, Icons.settings_rounded, Icons.settings_outlined, 'Settings'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem(int index, IconData selectedIcon, IconData unselectedIcon, String label) {
    final isSelected = _currentTab == index;
    return GestureDetector(
      onTap: () => setState(() => _currentTab = index),
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? AppTheme.primary.withValues(alpha: 0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isSelected ? selectedIcon : unselectedIcon,
              color: isSelected ? AppTheme.primary : Colors.white38,
              size: 24,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? AppTheme.primary : Colors.white38,
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHomeTab() {
    return SafeArea(
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHeader(),
                  const SizedBox(height: 32),
                  _buildUrlInput(),
                  const SizedBox(height: 16),
                  _buildQualitySelector(),
                  const SizedBox(height: 20),
                  _buildDownloadButton(),
                  const SizedBox(height: 32),
                  _buildSupportedPlatforms(),
                  const SizedBox(height: 32),
                  _buildQuickTips(),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [AppTheme.primary, AppTheme.primaryDark],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.download_rounded, color: Colors.white, size: 22),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'HieL SmD',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.onBackground,
                    letterSpacing: -0.5,
                  ),
                ),
                Text(
                  'No ads. Just downloads.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildUrlInput() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Paste video URL',
          style: TextStyle(
            color: AppTheme.onSurface,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            boxShadow: _urlValid
                ? [
                    BoxShadow(
                      color: AppTheme.primary.withValues(alpha: 0.2),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    )
                  ]
                : null,
          ),
          child: TextField(
            controller: _urlController,
            focusNode: _focusNode,
            style: const TextStyle(color: AppTheme.onBackground, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'https://youtube.com/watch?v=...',
              prefixIcon: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: _urlValid
                    ? Icon(
                        _detectedPlatform.icon,
                        key: ValueKey(_detectedPlatform),
                        color: _detectedPlatform.color,
                        size: 20,
                      )
                    : const Icon(
                        Icons.link_rounded,
                        key: ValueKey('default'),
                        color: Colors.white38,
                        size: 20,
                      ),
              ),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_urlController.text.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.clear_rounded, color: Colors.white38, size: 18),
                      onPressed: () {
                        _urlController.clear();
                        setState(() {
                          _urlValid = false;
                          _detectedPlatform = SupportedPlatform.generic;
                        });
                      },
                    ),
                  TextButton.icon(
                    onPressed: _pasteFromClipboard,
                    icon: const Icon(Icons.content_paste_rounded, size: 16),
                    label: const Text('Paste'),
                    style: TextButton.styleFrom(
                      foregroundColor: AppTheme.primary,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                  ),
                ],
              ),
            ),
            onSubmitted: (_) {
              if (_urlValid) _startDownload();
            },
          ),
        ),
        if (_urlValid) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.check_circle_rounded, color: AppTheme.success, size: 14),
              const SizedBox(width: 4),
              Text(
                'Detected: ${_detectedPlatform.displayName}',
                style: const TextStyle(
                  color: AppTheme.success,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildQualitySelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Quality',
          style: TextStyle(
            color: AppTheme.onSurface,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: VideoQuality.values.map((q) {
              final selected = _selectedQuality == q;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: GestureDetector(
                  onTap: () => setState(() => _selectedQuality = q),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: selected
                          ? AppTheme.primary.withValues(alpha: 0.2)
                          : AppTheme.surfaceVariant,
                      border: Border.all(
                        color: selected ? AppTheme.primary : Colors.transparent,
                        width: 1.5,
                      ),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (q == VideoQuality.audioOnly)
                          const Icon(Icons.music_note_rounded, size: 14, color: AppTheme.secondary)
                        else if (selected)
                          const Icon(Icons.hd_rounded, size: 14, color: AppTheme.primary),
                        if (q == VideoQuality.audioOnly || selected)
                          const SizedBox(width: 4),
                        Text(
                          q.label,
                          style: TextStyle(
                            color: selected ? AppTheme.primary : AppTheme.onSurface,
                            fontSize: 13,
                            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildDownloadButton() {
    return SizedBox(
      width: double.infinity,
      child: AnimatedBuilder(
        animation: _pulseAnimation,
        builder: (context, child) {
          return Transform.scale(
            scale: _urlValid ? _pulseAnimation.value : 1.0,
            child: child,
          );
        },
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: LinearGradient(
              colors: _urlValid
                  ? [AppTheme.primary, AppTheme.primaryDark]
                  : [AppTheme.surfaceVariant, AppTheme.surfaceVariant],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: _urlValid
                ? [
                    BoxShadow(
                      color: AppTheme.primary.withValues(alpha: 0.4),
                      blurRadius: 20,
                      offset: const Offset(0, 6),
                    )
                  ]
                : [],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _urlValid ? _startDownload : null,
              borderRadius: BorderRadius.circular(14),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.download_rounded,
                      color: _urlValid ? Colors.white : Colors.white30,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Download Now',
                      style: TextStyle(
                        color: _urlValid ? Colors.white : Colors.white30,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSupportedPlatforms() {
    final platforms = SupportedPlatform.values
        .where((p) => p != SupportedPlatform.generic)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Supported Platforms',
          style: TextStyle(
            color: AppTheme.onSurface,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: platforms.map((p) => PlatformBadge(platform: p)).toList(),
        ),
      ],
    );
  }

  Widget _buildQuickTips() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surfaceVariant,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppTheme.primary.withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.lightbulb_outline_rounded, color: AppTheme.warning, size: 16),
              const SizedBox(width: 6),
              Text(
                'Tips',
                style: TextStyle(
                  color: AppTheme.warning,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _tip('Share a video from any app and tap "Share to HieL SmD"'),
          _tip('YouTube: works with videos, shorts and playlists links'),
          _tip('For Instagram/TikTok: use the "Copy Link" option in the app'),
          _tip('Audio Only saves as .webm (YouTube) - no re-encoding for speed'),
        ],
      ),
    );
  }

  Widget _tip(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('• ', style: TextStyle(color: Colors.white38, fontSize: 12)),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: AppTheme.onSurface.withValues(alpha: 0.7),
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Download Options Sheet ───────────────────────────────────────────────────

class _DownloadOptions {
  final String url;
  final VideoQuality quality;
  const _DownloadOptions({required this.url, required this.quality});
}

class _DownloadOptionsSheet extends StatefulWidget {
  final String url;
  final VideoQuality initialQuality;

  const _DownloadOptionsSheet({
    required this.url,
    required this.initialQuality,
  });

  @override
  State<_DownloadOptionsSheet> createState() => _DownloadOptionsSheetState();
}

class _DownloadOptionsSheetState extends State<_DownloadOptionsSheet> {
  late VideoQuality _quality;
  late SupportedPlatform _platform;

  // Format toggle: false = video, true = audio only
  bool _audioOnly = false;

  @override
  void initState() {
    super.initState();
    _platform = detectPlatform(widget.url);
    _quality = widget.initialQuality == VideoQuality.audioOnly
        ? VideoQuality.best
        : widget.initialQuality;
    _audioOnly = widget.initialQuality == VideoQuality.audioOnly;
  }

  VideoQuality get _effectiveQuality =>
      _audioOnly ? VideoQuality.audioOnly : _quality;

  // Quality options shown for video mode
  static const _videoQualities = [
    VideoQuality.best,
    VideoQuality.hd1080,
    VideoQuality.hd720,
    VideoQuality.sd480,
    VideoQuality.sd360,
  ];

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + bottomInset),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.07),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Handle bar
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),

          // Header: platform icon + title
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: _platform.color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(_platform.icon, color: _platform.color, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Download Options',
                      style: TextStyle(
                        color: AppTheme.onBackground,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      _platform.displayName,
                      style: TextStyle(
                        color: _platform.color,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // URL preview
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.surfaceVariant,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                const Icon(Icons.link_rounded, color: Colors.white38, size: 15),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Format toggle: Video / Audio
          const Text(
            'Format',
            style: TextStyle(
              color: AppTheme.onSurface,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _FormatChip(
                label: 'Video (MP4)',
                icon: Icons.videocam_rounded,
                selected: !_audioOnly,
                onTap: () => setState(() => _audioOnly = false),
              ),
              const SizedBox(width: 10),
              _FormatChip(
                label: 'Audio Only (MP3)',
                icon: Icons.music_note_rounded,
                selected: _audioOnly,
                onTap: () => setState(() => _audioOnly = true),
                accentColor: AppTheme.secondary,
              ),
            ],
          ),

          // Quality picker — only shown for video
          if (!_audioOnly) ...[
            const SizedBox(height: 20),
            const Text(
              'Quality',
              style: TextStyle(
                color: AppTheme.onSurface,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _videoQualities.map((q) {
                final selected = _quality == q;
                return GestureDetector(
                  onTap: () => setState(() => _quality = q),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: selected
                          ? AppTheme.primary.withValues(alpha: 0.2)
                          : AppTheme.surfaceVariant,
                      border: Border.all(
                        color: selected
                            ? AppTheme.primary
                            : Colors.transparent,
                        width: 1.5,
                      ),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      q.label,
                      style: TextStyle(
                        color: selected
                            ? AppTheme.primary
                            : AppTheme.onSurface,
                        fontSize: 13,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],

          const SizedBox(height: 24),

          // Action buttons
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white54,
                    side: const BorderSide(color: Colors.white12),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: ElevatedButton.icon(
                  onPressed: () => Navigator.pop(
                    context,
                    _DownloadOptions(
                      url: widget.url,
                      quality: _effectiveQuality,
                    ),
                  ),
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: const Text('Download'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    textStyle: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FormatChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  final Color accentColor;

  const _FormatChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.accentColor = AppTheme.primary,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? accentColor.withValues(alpha: 0.18)
              : AppTheme.surfaceVariant,
          border: Border.all(
            color: selected ? accentColor : Colors.transparent,
            width: 1.5,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 16,
                color: selected ? accentColor : Colors.white38),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: selected ? accentColor : AppTheme.onSurface,
                fontSize: 13,
                fontWeight:
                    selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
