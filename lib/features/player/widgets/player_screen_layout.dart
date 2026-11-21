import 'package:bunpod/bunpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:material_ui/material_ui.dart';
import 'package:material_wavy_progress_indicator/material_wavy_progress_indicator.dart';

/// Shared player presentation for podcast and note audio.
/// Episode playback and note playback remain owned by their respective pages.
class PlayerScreenLayout extends StatelessWidget {
  const PlayerScreenLayout({
    super.key,
    required this.title,
    required this.scheme,
    required this.remainingLabel,
    required this.progress,
    required this.playing,
    required this.loading,
    required this.fav,
    required this.controlsEnabled,
    required this.onPlayPause,
    required this.onRewind,
    required this.onFastForward,
    required this.onFav,
    this.channelLabel,
    this.onChannelTap,
    this.titleArea,
    this.statusMessage,
  });

  final String title;
  final ColorScheme scheme;
  final String remainingLabel;
  final double progress;
  final bool playing;
  final bool loading;
  final bool fav;
  final bool controlsEnabled;
  final VoidCallback onPlayPause;
  final VoidCallback onRewind;
  final VoidCallback onFastForward;
  final VoidCallback onFav;
  final String? channelLabel;
  final VoidCallback? onChannelTap;
  final Widget? titleArea;
  final String? statusMessage;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = scheme;
    final TextTheme tt = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        backgroundColor: cs.surface,
        leading: const StyledBackButton(),
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            16.gap,
            GestureDetector(
              onTap: onChannelTap,
              behavior: HitTestBehavior.opaque,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    channelLabel?.toUpperCase() ?? '',
                    style: tt.labelMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  4.gap,
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: channelLabel == null
                        ? Colors.transparent
                        : cs.onSurfaceVariant,
                  ),
                ],
              ),
            ),
            12.gap,
            if (titleArea == null) ...[
              Padding(
                padding: const EdgeInsets.only(right: 56),
                child: Text(
                  title,
                  style: tt.headlineLarge?.copyWith(
                    color: cs.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (statusMessage == null)
                const Spacer()
              else
                Expanded(
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        statusMessage!,
                        textAlign: TextAlign.center,
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ),
                  ),
                ),
            ] else
              Expanded(
                child: Column(
                  children: [
                    Expanded(child: titleArea!),
                    if (statusMessage != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4, bottom: 8),
                        child: Text(
                          statusMessage!,
                          textAlign: TextAlign.center,
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(color: cs.onSurfaceVariant),
                        ),
                      ),
                  ],
                ),
              ),
            _Progress(
              remainingLabel: remainingLabel,
              progress: progress,
              scheme: cs,
            ),
            24.gap,
            PlayerControls(
              scheme: cs,
              playing: playing,
              loading: loading,
              fav: fav,
              enabled: controlsEnabled,
              onPlayPause: onPlayPause,
              onRewind: onRewind,
              onFastForward: onFastForward,
              onFav: onFav,
            ),
            const BottomPadding(),
          ],
        ),
      ),
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({
    required this.remainingLabel,
    required this.progress,
    required this.scheme,
  });

  final String remainingLabel;
  final double progress;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          remainingLabel,
          textAlign: TextAlign.right,
          style: GoogleFonts.unbounded(
            color: scheme.onSurface,
            fontSize: 56,
            fontWeight: FontWeight.w700,
            letterSpacing: -2,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        8.gap,
        WavyLinearProgressIndicator(
          value: progress.clamp(0.0, 1.0),
          color: scheme.primary,
          trackColor: scheme.onSurface.withValues(alpha: 0.14),
          stopIndicatorColor: scheme.primary,
        ),
      ],
    );
  }
}
