import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';
import 'package:path_provider/path_provider.dart';

enum VideoGenerationPhase {
  connecting,
  uploading,
  submitting,
  waitingForJob,
  downloading,
  done,
  failed,
}

class VideoGenerationProgress {
  final VideoGenerationPhase phase;
  final String message;
  final int downloadedCount; // 0–5
  final String? error;

  const VideoGenerationProgress({
    required this.phase,
    required this.message,
    this.downloadedCount = 0,
    this.error,
  });
}

/// Service that uploads a session CSV to the McMaster HPC server, submits a
/// Slurm job to generate 5 camera-angle MP4s, polls until complete, and
/// downloads the results to the app's documents directory under
/// `3d_videos/<sessionBaseName>/`.
class VideoGenerationService {
  static const int totalViews = 5;

  static const String _host = 'srv-cad.ece.mcmaster.ca';
  static const int _port = 22;
  static const String _username = 'let36';
  static const String _password = '400385350';
  static const String _remoteDataDir = '/home/let36/capstone/data';
  static const String _remoteScriptsDir = '/home/let36/capstone/scripts';
  static const String _remoteOutputDir =
      '/home/let36/capstone/scripts/outputs';

  /// Runs the full pipeline. Progress updates are delivered via [onProgress].
  /// Returns the list of local [File] paths for the downloaded videos,
  /// or throws if a fatal error occurs.
  ///
  /// [sessionCsvPath] — absolute path to the local session CSV file.
  static Future<List<File>> generate({
    required String sessionCsvPath,
    required void Function(VideoGenerationProgress) onProgress,
  }) async {
    final csvFile = File(sessionCsvPath);
    if (!await csvFile.exists()) {
      throw Exception('Session CSV not found at $sessionCsvPath');
    }

    final fileName = sessionCsvPath.split('/').last;
    final baseName = fileName.replaceAll('.csv', '');
    final remoteCsvPath = '$_remoteDataDir/$fileName';

    // Local output directory: <appDocuments>/3d_videos/<baseName>/
    final docsDir = await getApplicationDocumentsDirectory();
    final localOutDir = Directory('${docsDir.path}/3d_videos/$baseName');
    if (!await localOutDir.exists()) {
      await localOutDir.create(recursive: true);
    }

    SSHClient? client;
    try {
      // ── 1. Connect ─────────────────────────────────────────────────────────
      onProgress(const VideoGenerationProgress(
        phase: VideoGenerationPhase.connecting,
        message: 'Connecting to McMaster server…',
      ));
      final socket = await SSHSocket.connect(_host, _port);
      client = SSHClient(
        socket,
        username: _username,
        onPasswordRequest: () => _password,
      );

      // ── 2. Upload CSV via SFTP ─────────────────────────────────────────────
      onProgress(VideoGenerationProgress(
        phase: VideoGenerationPhase.uploading,
        message: 'Uploading $fileName to server…',
      ));
      final sftp = await client.sftp();
      final remoteFile = await sftp.open(
        remoteCsvPath,
        mode: SftpFileOpenMode.create |
            SftpFileOpenMode.write |
            SftpFileOpenMode.truncate,
      );
      await remoteFile.write(csvFile.openRead().cast<Uint8List>());
      await remoteFile.close();

      // ── 3. Submit Slurm job ────────────────────────────────────────────────
      onProgress(const VideoGenerationProgress(
        phase: VideoGenerationPhase.submitting,
        message: 'Submitting HPC job…',
      ));
      final cmd =
          'cd $_remoteScriptsDir && conda activate sam3 && sbatch run_script.sh $remoteCsvPath';
      final result = await client.run(cmd);
      final output = utf8.decode(result).trim();
      // Slurm prints "Submitted batch job <id>"
      final jobId = output.split(' ').last;
      if (jobId.isEmpty || int.tryParse(jobId) == null) {
        throw Exception('Unexpected sbatch output: $output');
      }

      // ── 4. Poll until done ─────────────────────────────────────────────────
      onProgress(VideoGenerationProgress(
        phase: VideoGenerationPhase.waitingForJob,
        message: 'Job $jobId queued — waiting for HPC…',
      ));
      while (true) {
        await Future.delayed(const Duration(seconds: 5));
        final check = await client.run('squeue -h -j $jobId');
        final status = utf8.decode(check).trim();
        if (status.isEmpty) break; // job finished (no longer in queue)
        // Parse state token: "123 debug run_script let36 R 0:14 1 node01"
        final tokens = status.split(RegExp(r'\s+'));
        final state = tokens.length > 4 ? tokens[4] : '?';
        final elapsed = tokens.length > 5 ? tokens[5] : '';
        onProgress(VideoGenerationProgress(
          phase: VideoGenerationPhase.waitingForJob,
          message: 'Job $jobId — state: $state  elapsed: $elapsed',
        ));
      }

      // ── 5. Download videos ────────────────────────────────────────────────
      final localFiles = <File>[];
      for (int i = 1; i <= totalViews; i++) {
        final videoName = '${baseName}_view$i.mp4';
        final remoteVideoPath = '$_remoteOutputDir/$videoName';
        final localVideoPath = '${localOutDir.path}/$videoName';

        onProgress(VideoGenerationProgress(
          phase: VideoGenerationPhase.downloading,
          message: 'Downloading view $i / $totalViews…',
          downloadedCount: i - 1,
        ));

        try {
          final remoteVideo = await sftp.open(remoteVideoPath);
          final localSink = File(localVideoPath).openWrite();
          await localSink.addStream(remoteVideo.read());
          await localSink.close();
          localFiles.add(File(localVideoPath));
        } catch (e) {
          // Non-fatal: some views may not exist; continue with the rest.
          onProgress(VideoGenerationProgress(
            phase: VideoGenerationPhase.downloading,
            message: 'Could not download view $i: $e',
            downloadedCount: i - 1,
          ));
        }
      }

      onProgress(VideoGenerationProgress(
        phase: VideoGenerationPhase.done,
        message: 'Done — ${localFiles.length} video(s) saved.',
        downloadedCount: localFiles.length,
      ));
      return localFiles;
    } catch (e) {
      onProgress(VideoGenerationProgress(
        phase: VideoGenerationPhase.failed,
        message: 'Failed: $e',
        error: e.toString(),
      ));
      rethrow;
    } finally {
      client?.close();
    }
  }

  /// Returns all previously generated video files for [sessionId], or an empty
  /// list if none exist yet.
  static Future<List<File>> cachedVideosFor(String sessionId) async {
    final baseName = sessionId.replaceAll('.csv', '');
    final docsDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${docsDir.path}/3d_videos/$baseName');
    if (!await dir.exists()) return [];
    return dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.mp4'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
  }
}
