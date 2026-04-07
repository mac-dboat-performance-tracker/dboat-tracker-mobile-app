import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import '../services/get_3d_video.dart';

class VideoGenerationScreen extends StatefulWidget {
  final String sessionId; // e.g. "Session_2025-01-01_10-00.csv"
  final String sessionName;

  const VideoGenerationScreen({
    super.key,
    required this.sessionId,
    required this.sessionName,
  });

  @override
  State<VideoGenerationScreen> createState() => _VideoGenerationScreenState();
}

class _VideoGenerationScreenState extends State<VideoGenerationScreen> {
  // Generation state
  bool _isRunning = false;
  final List<VideoGenerationProgress> _log = [];
  VideoGenerationProgress? _latest;
  List<File> _videos = [];

  // Video player state
  int _currentView = 0;
  final Map<int, VideoPlayerController> _controllers = {};

  @override
  void initState() {
    super.initState();
    _loadCachedVideos();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadCachedVideos() async {
    final cached = await VideoGenerationService.cachedVideosFor(widget.sessionId);
    if (cached.isNotEmpty && mounted) {
      setState(() => _videos = cached);
      await _initPlayer(0);
    }
  }

  Future<String> _csvPathForSession() async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/${widget.sessionId}';
  }

  Future<void> _startGeneration() async {
    if (_isRunning) return;
    // Dispose any existing players before re-generating.
    for (final c in _controllers.values) {
      await c.dispose();
    }
    _controllers.clear();
    setState(() {
      _isRunning = true;
      _log.clear();
      _videos = [];
      _latest = null;
      _currentView = 0;
    });

    final csvPath = await _csvPathForSession();
    try {
      final results = await VideoGenerationService.generate(
        sessionCsvPath: csvPath,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() {
            _latest = progress;
            _log.add(progress);
          });
        },
      );
      if (mounted) {
        setState(() {
          _videos = results;
          _isRunning = false;
        });
        if (results.isNotEmpty) await _initPlayer(0);
      }
    } catch (_) {
      if (mounted) setState(() => _isRunning = false);
    }
  }

  Future<void> _initPlayer(int index) async {
    if (_controllers.containsKey(index)) return;
    final controller = VideoPlayerController.file(_videos[index]);
    await controller.initialize();
    controller.setLooping(true);
    if (mounted) {
      setState(() => _controllers[index] = controller);
      if (index == _currentView) controller.play();
    }
  }

  void _switchView(int index) async {
    if (index == _currentView) return;
    _controllers[_currentView]?.pause();
    setState(() => _currentView = index);
    await _initPlayer(index);
    _controllers[index]?.play();
  }

  // ────────────────────────────────────────────────────────────────────────────
  // Build
  // ────────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('3D Video Generation', style: TextStyle(fontSize: 14)),
            Text(
              widget.sessionName,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        backgroundColor: Colors.blue.shade700,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildActionCard(),
          const SizedBox(height: 16),
          if (_isRunning || _log.isNotEmpty) _buildProgressCard(),
          if (_videos.isNotEmpty) ...[
            const SizedBox(height: 16),
            _buildVideoCard(),
          ],
        ],
      ),
    );
  }

  Widget _buildActionCard() {
    final hasCached = _videos.isNotEmpty && !_isRunning;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.videocam, color: Colors.blue.shade700),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  '3D Paddle Visualisation',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Uploads this session\'s CSV to the McMaster HPC server, runs the '
            '3D animation pipeline via Slurm, and downloads 5 camera-angle '
            'MP4 videos. This typically takes a few minutes.',
            style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isRunning ? null : _startGeneration,
              icon: _isRunning
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(hasCached ? Icons.refresh : Icons.play_arrow),
              label: Text(
                _isRunning
                    ? 'Generating…'
                    : hasCached
                        ? 'Regenerate'
                        : 'Generate 3D Videos',
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue.shade700,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                disabledBackgroundColor: Colors.grey.shade300,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressCard() {
    final phase = _latest?.phase;
    final phaseIcon = _phaseIcon(phase);
    final phaseColor = _phaseColor(phase);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(phaseIcon, color: phaseColor, size: 20),
              const SizedBox(width: 8),
              Text(
                _phaseLabel(phase),
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: phaseColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_latest != null)
            Text(
              _latest!.message,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
            ),
          // Download progress bar
          if (phase == VideoGenerationPhase.downloading ||
              phase == VideoGenerationPhase.done) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: (_latest?.downloadedCount ?? 0) /
                    VideoGenerationService.totalViews,
                minHeight: 8,
                backgroundColor: Colors.grey.shade200,
                valueColor: AlwaysStoppedAnimation<Color>(phaseColor),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${_latest?.downloadedCount ?? 0} / ${VideoGenerationService.totalViews} videos',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
          ],
          // Scrollable log
          if (_log.length > 1) ...[
            const SizedBox(height: 12),
            const Divider(),
            const SizedBox(height: 4),
            const Text(
              'Log',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: 120,
              child: ListView.builder(
                itemCount: _log.length,
                itemBuilder: (_, i) {
                  final entry = _log[_log.length - 1 - i]; // newest first
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1),
                    child: Text(
                      entry.message,
                      style: TextStyle(
                        fontSize: 11,
                        color: entry.phase == VideoGenerationPhase.failed
                            ? Colors.red.shade700
                            : Colors.grey.shade600,
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildVideoCard() {
    final controller = _controllers[_currentView];
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.movie, color: Colors.blue.shade700),
              const SizedBox(width: 8),
              Text(
                'View ${_currentView + 1} of ${_videos.length}',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Camera-angle tabs
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: List.generate(_videos.length, (i) {
                final active = i == _currentView;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text('View ${i + 1}'),
                    selected: active,
                    onSelected: (_) => _switchView(i),
                    selectedColor: Colors.blue.shade700,
                    labelStyle: TextStyle(
                      color: active ? Colors.white : Colors.grey.shade700,
                      fontWeight:
                          active ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                );
              }),
            ),
          ),
          const SizedBox(height: 12),
          // Video player area
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: controller != null && controller.value.isInitialized
                ? AspectRatio(
                    aspectRatio: controller.value.aspectRatio,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        VideoPlayer(controller),
                        // Play / pause tap overlay
                        GestureDetector(
                          onTap: () {
                            setState(() {
                              controller.value.isPlaying
                                  ? controller.pause()
                                  : controller.play();
                            });
                          },
                          child: AnimatedOpacity(
                            opacity: controller.value.isPlaying ? 0.0 : 1.0,
                            duration: const Duration(milliseconds: 200),
                            child: Container(
                              color: Colors.black26,
                              child: const Icon(
                                Icons.play_arrow,
                                color: Colors.white,
                                size: 64,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : const SizedBox(
                    height: 180,
                    child: Center(child: CircularProgressIndicator()),
                  ),
          ),
          const SizedBox(height: 8),
          // Scrub bar
          if (controller != null && controller.value.isInitialized)
            VideoProgressIndicator(
              controller,
              allowScrubbing: true,
              padding: EdgeInsets.zero,
              colors: VideoProgressColors(
                playedColor: Colors.blue.shade700,
                bufferedColor: Colors.blue.shade200,
                backgroundColor: Colors.grey.shade200,
              ),
            ),
        ],
      ),
    );
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  IconData _phaseIcon(VideoGenerationPhase? p) => switch (p) {
        VideoGenerationPhase.connecting => Icons.wifi,
        VideoGenerationPhase.uploading => Icons.upload,
        VideoGenerationPhase.submitting => Icons.send,
        VideoGenerationPhase.waitingForJob => Icons.hourglass_top,
        VideoGenerationPhase.downloading => Icons.download,
        VideoGenerationPhase.done => Icons.check_circle,
        VideoGenerationPhase.failed => Icons.error,
        null => Icons.info,
      };

  Color _phaseColor(VideoGenerationPhase? p) => switch (p) {
        VideoGenerationPhase.done => Colors.green.shade700,
        VideoGenerationPhase.failed => Colors.red.shade700,
        null => Colors.grey,
        _ => Colors.blue.shade700,
      };

  String _phaseLabel(VideoGenerationPhase? p) => switch (p) {
        VideoGenerationPhase.connecting => 'Connecting',
        VideoGenerationPhase.uploading => 'Uploading CSV',
        VideoGenerationPhase.submitting => 'Submitting Job',
        VideoGenerationPhase.waitingForJob => 'HPC Job Running',
        VideoGenerationPhase.downloading => 'Downloading Videos',
        VideoGenerationPhase.done => 'Complete',
        VideoGenerationPhase.failed => 'Failed',
        null => 'Starting',
      };
}
