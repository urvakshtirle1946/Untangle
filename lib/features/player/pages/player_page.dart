import 'package:bunpod/bunpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../widgets/player_screen_layout.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.episode,
    this.fromChannel = false,
  });

  final Episode episode;

  /// Whether the player was opened from this episode's channel page. When true,
  /// tapping the channel name pops back instead of pushing a duplicate page.
  final bool fromChannel;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  bool _fav = false;

  void _openChannel() {
    if (widget.fromChannel) {
      Navigator.of(context).pop();
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) {
          return ChannelPage(
            id: widget.episode.channelId,
            preview: ChannelPreview.fromChannel(widget.episode.channel),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Episode episode = widget.episode;
    final ColorScheme cs = episode.scheme(context);
    return EpisodeProgressBuilder(
      episode: episode,
      builder: (context, updatedEpisode) {
        final PlayerCubit player = locator<PlayerCubit>();
        final bool current = player.state.episode?.id == episode.id;
        final Duration loaded = current ? player.duration : Duration.zero;
        final Duration total = loaded > Duration.zero
            ? loaded
            : updatedEpisode.total;
        final Duration position = updatedEpisode.listened;
        final Duration remaining = total - position;
        final double progress = total.inMilliseconds == 0
            ? 0
            : position.inMilliseconds / total.inMilliseconds;

        return BlocBuilder<PlayerCubit, Playback>(
          bloc: player,
          builder: (context, playback) {
            final bool isCurrent = playback.episode?.id == episode.id;
            return PlayerScreenLayout(
              title: episode.title ?? '',
              channelLabel: episode.channel?.title ?? '',
              onChannelTap: _openChannel,
              scheme: cs,
              remainingLabel: remaining > Duration.zero
                  ? '-${remaining.remainingLabel}'
                  : total.remainingLabel,
              progress: progress,
              playing: isCurrent && playback.playing,
              loading: isCurrent && playback.loading,
              fav: _fav,
              controlsEnabled: true,
              onPlayPause: () {
                if (isCurrent && playback.playing) {
                  HapticsHelper.light();
                  player.toggle();
                  return;
                }

                HapticsHelper.medium();
                isCurrent ? player.toggle() : player.play(episode);
              },
              onRewind: () {
                if (!isCurrent) return;
                HapticsHelper.light();
                player.rewind();
              },
              onFastForward: () {
                if (!isCurrent) return;
                HapticsHelper.light();
                player.fastForward();
              },
              onFav: () {
                // TODO(kamran): remove once favorites ship.
                ComingSoon.show(context);
                return;

                // ignore: dead_code
                _fav ? HapticsHelper.light() : HapticsHelper.success();
                setState(() => _fav = !_fav);
              },
            );
          },
        );
      },
    );
  }
}
