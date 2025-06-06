import "dart:async";
import "dart:math";
import "dart:io" show Directory;

import "package:flutter_cast_framework/cast.dart";
import "package:flutter_cast_framework/widgets.dart";
import "package:unofficial_filman_client/notifiers/filman.dart";
import "package:unofficial_filman_client/notifiers/settings.dart";
import "package:unofficial_filman_client/notifiers/watched.dart";
import "package:unofficial_filman_client/types/film_details.dart";
import "package:unofficial_filman_client/types/season.dart";
import "package:unofficial_filman_client/types/video_scrapers.dart";
import "package:unofficial_filman_client/types/watched.dart";
import "package:unofficial_filman_client/utils/select_dialog.dart";
import "package:unofficial_filman_client/utils/title.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:media_kit/media_kit.dart" hide PlayerState;
import "package:media_kit_video/media_kit_video.dart";
import "package:provider/provider.dart";
import "package:screen_brightness/screen_brightness.dart";
import "package:unofficial_filman_client/types/download.dart";
import "package:path_provider/path_provider.dart";
import "package:collection/collection.dart";

class FilmanPlayer extends StatefulWidget {
  final String targetUrl;
  final FilmDetails? filmDetails;
  final FilmDetails? parentDetails;
  final int startFrom;
  final int savedDuration;
  final FlutterCastFramework? castFramework;
  final DownloadedSingle? downloaded;
  final DownloadedSerial? parentDownloaded;

  const FilmanPlayer(
      {super.key,
      required this.targetUrl,
      this.parentDetails,
      this.startFrom = 0,
      this.savedDuration = 0,
      this.castFramework})
      : filmDetails = null,
        downloaded = null,
        parentDownloaded = null;

  const FilmanPlayer.fromDetails(
      {super.key,
      required this.filmDetails,
      this.parentDetails,
      this.startFrom = 0,
      this.savedDuration = 0,
      this.castFramework})
      : targetUrl = "",
        downloaded = null,
        parentDownloaded = null;

  FilmanPlayer.fromDownload(
      {super.key,
      required this.downloaded,
      this.parentDownloaded,
      this.startFrom = 0,
      this.savedDuration = 0,
      this.castFramework})
      : targetUrl = "",
        filmDetails = downloaded?.film,
        parentDetails = parentDownloaded?.serial;

  @override
  State<FilmanPlayer> createState() => _FilmanPlayerState();
}

enum SeekDirection { forward, backward }

class _FilmanPlayerState extends State<FilmanPlayer> {
  late final Player _player;
  late final VideoController _controller;
  late final StreamSubscription<Duration> _positionSubscription;
  late final StreamSubscription<Duration?> _durationSubscription;
  late final StreamSubscription<bool> _playingSubscription;
  late final StreamSubscription<bool> _bufferingSubscription;

  bool _isOverlayVisible = true;
  bool _isBuffering = true;
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  late FilmDetails _filmDetails;

  FilmDetails? _parentDetails;
  Season? _currentSeason;
  SeekDirection? _seekDirection;
  bool _isSeeking = false;
  FilmDetails? _nextEpisode;
  DownloadedSingle? _nextDwonloaded;
  String _displayState = "Ładowanie...";

  late FlutterCastFramework _castFramework;
  String? _direct;
  CastState? _castState;

  @override
  void initState() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    _initMediaKit();
    _initSubscriptions();
    _initPlayer();
    _initCast();
    super.initState();
  }

  void _initCast() {
    if (widget.castFramework != null) {
      _castFramework = widget.castFramework!;
    } else {
      _castFramework = FlutterCastFramework.create([
        "urn:x-cast:majusss-unofficial-filman-client",
      ]);
    }
    _castFramework.castContext.state.addListener(
      () async {
        setState(() {
          _castState = _castFramework.castContext.state.value;
        });
        switch (_castFramework.castContext.state.value) {
          case CastState.connected:
            _castVideo();
            break;
          case CastState.idle:
          default:
            break;
        }
      },
    );

    final sessionManager = _castFramework.castContext.sessionManager;
    sessionManager.remoteMediaClient.onProgressUpdated =
        (final progressMs, final durationMs) {
      setState(() {
        _position = Duration(milliseconds: progressMs);
      });
    };
  }

  void _initMediaKit() {
    _player = Player();
    _controller = VideoController(_player);
    _position = Duration(seconds: widget.startFrom);
    _duration = Duration(seconds: widget.savedDuration);
  }

  void _initSubscriptions() {
    _positionSubscription =
        _controller.player.stream.position.listen((final position) {
      if (widget.startFrom != 0) {
        if (position.inSeconds != 0) {
          setState(() => _position = position);
        }
      } else {
        setState(() => _position = position);
      }
    });

    _durationSubscription =
        _controller.player.stream.duration.listen((final duration) {
      if (duration.inSeconds > widget.savedDuration) {
        setState(() => _duration = duration);
      }

      if (widget.startFrom > 0) {
        _controller.player.seek(Duration(seconds: widget.startFrom));
      }
      _saveWatched();
      Timer.periodic(const Duration(seconds: 5), (final timer) {
        if (mounted) {
          _saveWatched();
        }
      });
    });

    _playingSubscription =
        _controller.player.stream.playing.listen((final playing) {
      setState(() {
        _isPlaying = playing;
      });
    });

    _bufferingSubscription =
        _controller.player.stream.buffering.listen((final buffering) {
      setState(() => _isBuffering = buffering);
    });
  }

  Future<void> _initPlayer() async {
    if (widget.filmDetails == null) {
      setState(() => _displayState = "Pobieranie informacji o filmie...");
      final details = await Provider.of<FilmanNotifier>(context, listen: false)
          .getFilmDetails(widget.targetUrl);
      setState(() => _filmDetails = details);
    } else {
      setState(() => _filmDetails = widget.filmDetails!);
    }

    if (_filmDetails.isEpisode == true) {
      if (widget.parentDetails != null) {
        setState(() => _parentDetails = widget.parentDetails);
      } else if (_filmDetails.parentUrl != null && mounted) {
        setState(() => _displayState = "Pobieranie informacji o serialu...");
        final parent = await Provider.of<FilmanNotifier>(context, listen: false)
            .getFilmDetails(_filmDetails.parentUrl ?? "");
        setState(() => _parentDetails = parent);
      }

      setState(() {
        _currentSeason = _parentDetails!.seasons!.firstWhere((final element) =>
            element.episodes.any((final element) =>
                element.episodeName == _filmDetails.seasonEpisodeTag));
      });
    }

    if (_filmDetails.isEpisode == true) {
      _loadNextEpisode();
    }

    if (widget.downloaded == null) {
      if (_filmDetails.links != null && mounted) {
        setState(() => _displayState = "Ładowanie listy mediów...");
        final link = await getUserSelectedVersion(_filmDetails.links!);
        debugPrint("Selected link: $link");
        if (link == null) return _showNoLinksSnackbar();
        setState(() => _displayState = "Wydobywanie adresu video...");
        final direct = await link.getDirectLink();
        setState(() {
          _direct = direct;
          _displayState = "";
        });
        if (_direct == null) return _showNoLinksSnackbar();
        _player.open(Media(_direct!, httpHeaders: {
          "referer": getBaseUrl(link.url),
        }));
      } else {
        return _showNoLinksSnackbar();
      }
    } else {
      _player.open(Media(Directory(
              "${(await getApplicationDocumentsDirectory()).path}/${widget.downloaded?.filename}")
          .path));
    }
  }

  void _saveWatched() {
    if (_duration.inSeconds == 0) return;
    if (_parentDetails != null && _filmDetails.isEpisode == true) {
      final WatchedSingle lastWatched = WatchedSingle.fromFilmDetails(
          filmDetailsFrom: _filmDetails,
          sec: _position.inSeconds,
          totalSec: _duration.inSeconds,
          parentSeason: _currentSeason);
      Provider.of<WatchedNotifier>(context, listen: false).watchEpisode(
          WatchedSerial.fromFilmDetails(
            filmDetailsFrom: _parentDetails!,
            lastWatchedFromDetails: lastWatched,
          ),
          lastWatched);
    } else if (_filmDetails.isEpisode == false) {
      Provider.of<WatchedNotifier>(context, listen: false).watch(
          WatchedSingle.fromFilmDetails(
              filmDetailsFrom: _filmDetails,
              sec: _position.inSeconds,
              totalSec: _duration.inSeconds));
    }
  }

  void _loadNextEpisode() async {
    final nextDownloaded = widget.parentDownloaded?.episodes.firstWhereOrNull(
        (final e) => e.film.url == _filmDetails.nextEpisodeUrl);
    if (nextDownloaded != null) {
      setState(() {
        _nextDwonloaded = nextDownloaded;
      });
      return;
    }
    if (_filmDetails.nextEpisodeUrl != null) {
      final FilmDetails next =
          await Provider.of<FilmanNotifier>(context, listen: false)
              .getFilmDetails(_filmDetails.nextEpisodeUrl ?? "");
      setState(() {
        _nextEpisode = next;
      });
    }
  }

  void _showNoLinksSnackbar() {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Brak dostępnych linków"),
        dismissDirection: DismissDirection.horizontal,
        behavior: SnackBarBehavior.floating,
        showCloseIcon: true,
      ));
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations(
        [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _positionSubscription.cancel();
    _durationSubscription.cancel();
    _playingSubscription.cancel();
    _bufferingSubscription.cancel();
    _player.dispose();

    super.dispose();
  }

  void _castVideo() async {
    _player.pause();
    _castFramework.castContext.sessionManager.remoteMediaClient.load(
        MediaLoadRequestData(
            currentTime: _position.inMilliseconds,
            shouldAutoplay: true,
            mediaInfo: MediaInfo(
                streamDuration: _duration.inMilliseconds,
                streamType: StreamType.buffered,
                contentType: "videos/mp4",
                contentId: _direct,
                mediaMetadata: MediaMetadata(
                    mediaType: MediaType.movie,
                    strings: _filmDetails.isEpisode
                        ? {
                            MediaMetadataKey.title.name:
                                _filmDetails.seasonEpisodeTag,
                            MediaMetadataKey.subtitle.name: _filmDetails.title,
                          }
                        : {MediaMetadataKey.title.name: _filmDetails.title},
                    webImages: [
                      WebImage(url: _filmDetails.imageUrl),
                      WebImage(url: _filmDetails.imageUrl)
                    ]))));
  }

  @override
  Widget build(final BuildContext context) {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations(
        [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);

    return Scaffold(
      body: Stack(
        children: [
          Video(
            controller: _controller,
            controls: NoVideoControls,
            fit: BoxFit.fitWidth,
          ),
          SafeArea(child: _buildOverlay()),
        ],
      ),
    );
  }

  Widget _buildOverlay() {
    return Stack(
      children: [
        _buildSeekingIcons(),
        _buildLoadingIcon(),
        _buildDoubleTapControls(),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: _isOverlayVisible
              ? Stack(
                  children: [
                    _buildTopBar(),
                    _buildCenterPlayPauseButton(),
                    _buildIconsBar(),
                    _buildBrightnessControl(),
                    _buildBottomBar(),
                  ],
                )
              : const SizedBox(),
        )
      ],
    );
  }

  Widget _buildIconsBar() {
    return Positioned(
        height: MediaQuery.of(context).size.height,
        right: 10,
        top: -10,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _castState != CastState.unavailable
                ? CastButton(
                    castFramework: _castFramework,
                    color: Colors.white,
                    activeColor: Theme.of(context).colorScheme.primary,
                  )
                : const SizedBox()
          ],
        ));
  }

  Widget _buildLoadingIcon() {
    if (_isBuffering) {
      return Center(
        child: AnimatedOpacity(
            opacity: _isBuffering ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 300),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(
                  height: 8,
                ),
                Text(
                  _displayState,
                ),
              ],
            )),
      );
    }
    return const SizedBox();
  }

  Widget _buildSeekingIcons() {
    return Center(
      child: Transform(
        transform: Matrix4.translationValues(
            _seekDirection == SeekDirection.forward ? 100 : -100, 0, 0),
        child: AnimatedOpacity(
            opacity: _isSeeking ? 1 : 0,
            duration: const Duration(milliseconds: 300),
            child: Icon(
              _seekDirection == SeekDirection.forward
                  ? Icons.fast_forward
                  : Icons.fast_rewind,
              size: 52,
            )),
      ),
    );
  }

  Widget _buildDoubleTapControls() {
    return Row(
      children: [
        SizedBox(
          height: double.infinity,
          width: MediaQuery.of(context).size.width * 0.5,
          child: InkWell(
            onTap: () {
              setState(() {
                _isOverlayVisible = !_isOverlayVisible;
              });
            },
            onDoubleTap: () {
              setState(() {
                _seekDirection = SeekDirection.backward;
                _isSeeking = true;
                Future.delayed(const Duration(milliseconds: 400), () {
                  setState(() {
                    _isSeeking = false;
                  });
                });
              });
              _player.seek(Duration(seconds: max(0, _position.inSeconds - 10)));
            },
          ),
        ),
        SizedBox(
          height: double.infinity,
          width: MediaQuery.of(context).size.width * 0.5,
          child: InkWell(
            onTap: () {
              setState(() {
                _isOverlayVisible = !_isOverlayVisible;
              });
            },
            onDoubleTap: () {
              setState(() {
                _seekDirection = SeekDirection.forward;
                _isSeeking = true;
                Future.delayed(const Duration(milliseconds: 400), () {
                  setState(() {
                    _isSeeking = false;
                  });
                });
              });
              _player.seek(Duration(
                  seconds: min(_position.inSeconds + 10, _duration.inSeconds)));
            },
          ),
        ),
      ],
    );
  }

  Widget _buildBrightnessControl() {
    return Positioned(
      left: 10,
      top: -10,
      height: MediaQuery.of(context).size.height,
      child: FutureBuilder<double>(
        future: ScreenBrightness().current,
        builder: (final context, final snapshot) {
          return Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              RotatedBox(
                quarterTurns: -1,
                child: Slider(
                  value: snapshot.data ?? 0,
                  min: 0,
                  max: 1,
                  onChanged: (final value) {
                    setState(() {
                      ScreenBrightness().setScreenBrightness(value);
                    });
                  },
                ),
              ),
              Icon(_getBrightnessIcon(snapshot.data ?? 0)),
            ],
          );
        },
      ),
    );
  }

  IconData _getBrightnessIcon(final double brightness) {
    if (brightness >= 0.875) return Icons.brightness_7;
    if (brightness >= 0.75) return Icons.brightness_6;
    if (brightness >= 0.625) return Icons.brightness_5;
    if (brightness >= 0.5) return Icons.brightness_4;
    if (brightness >= 0.375) return Icons.brightness_1;
    if (brightness >= 0.25) return Icons.brightness_2;
    if (brightness >= 0.125) return Icons.brightness_3;
    return Icons.brightness_3;
  }

  Widget _buildTopBar() {
    return Align(
      alignment: Alignment.topCenter,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        // duration: const Duration(milliseconds: 400),
        // transform: Matrix4.translationValues(
        //     0.0, _isOverlayVisible ? 0.0 : -48.0, 0.0),
        // curve: Curves.easeInOut,
        width: double.infinity,
        height: 48,
        child: Stack(
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () {
                  _saveWatched();
                  Navigator.of(context).pop();
                },
              ),
            ),
            Center(
              child: Consumer<SettingsNotifier>(
                builder: (final context, final settings, final child) {
                  try {
                    final displayTitle =
                        getDisplayTitle(_filmDetails.title, settings);

                    return Text(
                      _filmDetails.isEpisode == true
                          ? "$displayTitle - ${_filmDetails.seasonEpisodeTag}"
                          : displayTitle,
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    );
                  } catch (err) {
                    return const SizedBox();
                  }
                },
              ),
            ),
            Align(
                alignment: Alignment.centerRight,
                child: AnimatedContainer(
                  transform: Matrix4.translationValues(
                      (_nextEpisode != null || _nextDwonloaded != null)
                          ? 0.0
                          : 100.0,
                      0.0,
                      0.0),
                  duration: const Duration(milliseconds: 300),
                  child: AnimatedOpacity(
                    opacity: (_nextEpisode != null || _nextDwonloaded != null)
                        ? 1.0
                        : 0.0,
                    duration: const Duration(milliseconds: 300),
                    child: OutlinedButton.icon(
                      icon: Text(_nextEpisode?.seasonEpisodeTag ??
                          _nextDwonloaded?.film.seasonEpisodeTag ??
                          "Następny odcinek"),
                      label: const Icon(Icons.arrow_forward),
                      onPressed: () {
                        Navigator.of(context).pushReplacement(
                            MaterialPageRoute(builder: (final context) {
                          if (_nextEpisode != null) {
                            return FilmanPlayer.fromDetails(
                                filmDetails: _nextEpisode,
                                castFramework: _castFramework);
                          }
                          if (_nextDwonloaded != null) {
                            return FilmanPlayer.fromDownload(
                              downloaded: _nextDwonloaded,
                              parentDownloaded: widget.parentDownloaded,
                              castFramework: _castFramework,
                            );
                          }
                          return const Center(child: Text("Wystąpił błąd"));
                        }));
                      },
                    ),
                  ),
                )),
          ],
        ),
      ),
    );
  }

  Widget _buildCenterPlayPauseButton() {
    return Center(
      child: _isBuffering
          ? const SizedBox()
          : IconButton(
              icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
              iconSize: 72,
              onPressed: () {
                _saveWatched();
                _player.playOrPause();
              },
            ),
    );
  }

  Widget _buildBottomBar() {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 56),
        width: double.infinity,
        height: 24,
        margin: const EdgeInsets.only(bottom: 32),
        child: Row(
          children: [
            Text(
              '${_position.inMinutes}:${(_position.inSeconds % 60).toString().padLeft(2, '0')}',
              style: const TextStyle(color: Colors.white),
            ),
            Expanded(
              child: Slider(
                value: _position.inSeconds.toDouble(),
                onChanged: (final value) {
                  _controller.player.seek(Duration(seconds: value.toInt()));
                  _saveWatched();
                },
                min: 0,
                max: _duration.inSeconds.toDouble(),
                activeColor: Theme.of(context).colorScheme.primary,
                inactiveColor: Colors.white,
              ),
            ),
            AnimatedOpacity(
                opacity: _duration == Duration.zero ? 0 : 1,
                duration: const Duration(milliseconds: 300),
                child: Text(
                    '${_duration.inMinutes}:${(_duration.inSeconds % 60).toString().padLeft(2, '0')}',
                    style: const TextStyle(color: Colors.white))),
          ],
        ),
      ),
    );
  }
}
