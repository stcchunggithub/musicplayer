import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Bridges to the custom Swift code in ios/Runner/BookmarkChannel.swift.
// This is what avoids copying audio files into the app's own storage:
// iOS's document picker hands back a "security-scoped bookmark" instead
// of a copy, and the app can re-resolve that bookmark on every future
// launch to get straight back to the original file in place.
const _channel = MethodChannel('mp3player/bookmarks');

void main() => runApp(const MP3PlayerApp());

class MP3PlayerApp extends StatelessWidget {
  const MP3PlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MP3 Player',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF17181C),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF8398FA),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const LibraryScreen(),
    );
  }
}

class Track {
  final String id; // stable id derived from the bookmark itself
  final String name;
  final String bookmark; // base64-encoded security-scoped bookmark data

  Track({required this.id, required this.name, required this.bookmark});

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'bookmark': bookmark};

  factory Track.fromJson(Map<String, dynamic> j) =>
      Track(id: j['id'], name: j['name'], bookmark: j['bookmark']);
}

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final _player = AudioPlayer();
  final List<Track> _library = [];
  int _currentIndex = -1;
  bool _selecting = false;
  final Set<String> _selectedIds = {};
  double _speed = 1.0;
  late SharedPreferences _prefs;
  bool _loading = true;

  static const _libraryKey = 'library_v1';
  static const _lastTrackKey = 'last_track_id';
  static const _speedKey = 'playback_speed';
  String _posKey(String id) => 'pos_$id';

  @override
  void initState() {
    super.initState();
    _init();
    _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        _onTrackFinished();
      }
      setState(() {});
    });
  }

  Future<void> _init() async {
    _prefs = await SharedPreferences.getInstance();
    final raw = _prefs.getStringList(_libraryKey) ?? [];
    _library.addAll(raw.map((s) => Track.fromJson(jsonDecode(s))));
    _speed = _prefs.getDouble(_speedKey) ?? 1.0;
    await _player.setSpeed(_speed);

    final lastId = _prefs.getString(_lastTrackKey);
    if (lastId != null) {
      final idx = _library.indexWhere((t) => t.id == lastId);
      if (idx != -1) await _loadTrack(idx, autoplay: false);
    }
    setState(() => _loading = false);
  }

  Future<void> _saveLibrary() async {
    await _prefs.setStringList(
      _libraryKey,
      _library.map((t) => jsonEncode(t.toJson())).toList(),
    );
  }

  // ---------------------------------------------------------------
  // Adding files — no bytes ever copied, only a bookmark reference.
  // ---------------------------------------------------------------

  Future<void> _addFiles() async {
    List<dynamic> picked;
    try {
      picked = await _channel.invokeMethod('pickFiles');
    } on PlatformException catch (e) {
      _showSnack('Could not open file picker: ${e.message}');
      return;
    }
    if (picked.isEmpty) return;

    final existingIds = _library.map((t) => t.id).toSet();
    var added = 0;
    for (final item in picked) {
      final map = Map<String, dynamic>.from(item as Map);
      final bookmark = map['bookmark'] as String;
      final name = map['name'] as String;
      final id = bookmark.hashCode.toString();
      if (existingIds.contains(id)) continue;
      _library.add(Track(id: id, name: name, bookmark: bookmark));
      existingIds.add(id);
      added++;
    }
    _library.sort((a, b) => a.name.compareTo(b.name));
    await _saveLibrary();
    setState(() {});
    if (added > 0) _showSnack('Added $added song${added == 1 ? '' : 's'}.');
  }

  // ---------------------------------------------------------------
  // Playback
  // ---------------------------------------------------------------

  Future<void> _loadTrack(int index, {required bool autoplay}) async {
    if (index < 0 || index >= _library.length) return;
    final track = _library[index];
    setState(() => _currentIndex = index);

    String path;
    try {
      final result = await _channel.invokeMethod('resolveBookmark', {
        'bookmark': track.bookmark,
      });
      path = (result as Map)['path'] as String;
    } on PlatformException catch (e) {
      _showSnack('Could not open "${track.name}" — ${e.message}');
      return;
    }

    final resumeAt = _prefs.getDouble(_posKey(track.id)) ?? 0;
    try {
      await _player.setFilePath(path);
      if (resumeAt > 0) {
        await _player.seek(Duration(milliseconds: (resumeAt * 1000).round()));
      }
      await _player.setSpeed(_speed);
      await _prefs.setString(_lastTrackKey, track.id);
      if (autoplay) await _player.play();
    } catch (e) {
      _showSnack('Playback error for "${track.name}".');
    }
  }

  void _onTrackFinished() {
    if (_currentIndex >= 0) _savePosition(0);
    _next();
  }

  void _savePosition(double seconds) {
    if (_currentIndex < 0) return;
    _prefs.setDouble(_posKey(_library[_currentIndex].id), seconds);
  }

  void _playPause() {
    if (_currentIndex == -1) {
      if (_library.isNotEmpty) _loadTrack(0, autoplay: true);
      return;
    }
    if (_player.playing) {
      _player.pause();
      _savePosition(_player.position.inMilliseconds / 1000);
    } else {
      _player.play();
    }
  }

  void _next() {
    if (_currentIndex + 1 < _library.length) {
      _loadTrack(_currentIndex + 1, autoplay: true);
    }
  }

  void _previous() {
    if (_currentIndex - 1 >= 0) {
      _loadTrack(_currentIndex - 1, autoplay: true);
    }
  }

  void _seekBy(int deltaSeconds) {
    final newPos = _player.position + Duration(seconds: deltaSeconds);
    final clamped = newPos < Duration.zero ? Duration.zero : newPos;
    _player.seek(clamped);
    _savePosition(clamped.inMilliseconds / 1000);
  }

  Future<void> _setSpeed(double speed) async {
    setState(() => _speed = speed);
    await _player.setSpeed(speed);
    await _prefs.setDouble(_speedKey, speed);
  }

  // ---------------------------------------------------------------
  // Batch remove — just drops the bookmark reference; there's no
  // on-device copy to clean up, since nothing was ever duplicated.
  // ---------------------------------------------------------------

  Future<void> _removeSelected() async {
    if (_selectedIds.isEmpty) return;
    final removingCurrent = _currentIndex >= 0 &&
        _selectedIds.contains(_library[_currentIndex].id);
    for (final id in _selectedIds) {
      await _prefs.remove(_posKey(id));
    }
    _library.removeWhere((t) => _selectedIds.contains(t.id));
    if (removingCurrent) {
      await _player.stop();
      _currentIndex = -1;
    }
    _selectedIds.clear();
    _selecting = false;
    await _saveLibrary();
    setState(() {});
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          if (_selecting)
            TextButton(
              onPressed: _removeSelected,
              child: Text('Remove (${_selectedIds.length})',
                  style: const TextStyle(color: Colors.redAccent)),
            ),
          TextButton(
            onPressed: () => setState(() {
              _selecting = !_selecting;
              _selectedIds.clear();
            }),
            child: Text(_selecting ? 'Cancel' : 'Select'),
          ),
          IconButton(onPressed: _addFiles, icon: const Icon(Icons.add)),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _library.isEmpty
                ? const Center(child: Text('No songs yet. Tap + to add some.'))
                : ListView.builder(
                    itemCount: _library.length,
                    itemBuilder: (context, i) {
                      final track = _library[i];
                      final isActive = i == _currentIndex;
                      return ListTile(
                        leading: _selecting
                            ? Checkbox(
                                value: _selectedIds.contains(track.id),
                                onChanged: (v) => setState(() {
                                  v == true
                                      ? _selectedIds.add(track.id)
                                      : _selectedIds.remove(track.id);
                                }),
                              )
                            : Text('${i + 1}',
                                style: const TextStyle(color: Colors.grey)),
                        title: Text(
                          track.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isActive
                                ? Theme.of(context).colorScheme.primary
                                : Colors.white,
                          ),
                        ),
                        onTap: () => _selecting
                            ? setState(() {
                                _selectedIds.contains(track.id)
                                    ? _selectedIds.remove(track.id)
                                    : _selectedIds.add(track.id);
                              })
                            : _loadTrack(i, autoplay: true),
                      );
                    },
                  ),
          ),
          if (_currentIndex != -1) _buildNowPlayingBar(),
        ],
      ),
    );
  }

  Widget _buildNowPlayingBar() {
    final track = _library[_currentIndex];
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF201F24),
        border: const Border(top: BorderSide(color: Color(0xFF313037))),
      ),
      child: Column(
        children: [
          Text(track.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          StreamBuilder<Duration>(
            stream: _player.positionStream,
            builder: (context, snapshot) {
              final pos = snapshot.data ?? Duration.zero;
              final dur = _player.duration ?? Duration.zero;
              return Column(
                children: [
                  Slider(
                    value: pos.inMilliseconds
                        .clamp(0, dur.inMilliseconds == 0 ? 1 : dur.inMilliseconds)
                        .toDouble(),
                    max: dur.inMilliseconds == 0 ? 1 : dur.inMilliseconds.toDouble(),
                    onChanged: (v) {
                      final target = Duration(milliseconds: v.round());
                      _player.seek(target);
                      _savePosition(target.inMilliseconds / 1000);
                    },
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(_fmt(pos)),
                      Text('-${_fmt(dur - pos)}'),
                    ],
                  ),
                ],
              );
            },
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(onPressed: _previous, icon: const Icon(Icons.skip_previous)),
              IconButton(onPressed: () => _seekBy(-15), icon: const Icon(Icons.replay_10)),
              IconButton(
                iconSize: 44,
                onPressed: _playPause,
                icon: Icon(_player.playing ? Icons.pause_circle_filled : Icons.play_circle_fill),
              ),
              IconButton(onPressed: () => _seekBy(15), icon: const Icon(Icons.forward_10)),
              IconButton(onPressed: _next, icon: const Icon(Icons.skip_next)),
            ],
          ),
          Wrap(
            spacing: 8,
            children: [1.0, 1.25, 1.5, 1.75, 2.0].map((s) {
              final selected = _speed == s;
              return ChoiceChip(
                label: Text('${s}x'),
                selected: selected,
                onSelected: (_) => _setSpeed(s),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  String _fmt(Duration d) {
    if (d.isNegative) return '0:00';
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
