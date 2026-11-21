import 'package:bunpod/bunpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as material_ui;
import 'package:material_wavy_progress_indicator/material_wavy_progress_indicator.dart';

import '../../../lib/features/player/widgets/player_screen_layout.dart';

void main() {
  testWidgets('shared layout preserves podcast control size and callbacks', (
    tester,
  ) async {
    tester.view.physicalSize = const material_ui.Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    int playCalls = 0;
    int rewindCalls = 0;
    int forwardCalls = 0;
    int favoriteCalls = 0;
    final material_ui.ColorScheme scheme = material_ui.ColorScheme.fromSeed(
      seedColor: const material_ui.Color(0xFF294B63),
    );

    await tester.pumpWidget(
      material_ui.MaterialApp(
        theme: MaterialThemes.light,
        home: PlayerScreenLayout(
          title: 'Podcast episode',
          channelLabel: 'Podcast channel',
          onChannelTap: () {},
          scheme: scheme,
          remainingLabel: '-12m',
          progress: 0.25,
          playing: false,
          loading: false,
          fav: false,
          controlsEnabled: true,
          onPlayPause: () => playCalls++,
          onRewind: () => rewindCalls++,
          onFastForward: () => forwardCalls++,
          onFav: () => favoriteCalls++,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('PODCAST CHANNEL'), findsOneWidget);
    expect(find.text('Podcast episode'), findsOneWidget);
    expect(find.text('-12m'), findsOneWidget);
    expect(find.byType(WavyLinearProgressIndicator), findsOneWidget);
    expect(find.byType(PlayerControls), findsOneWidget);
    expect(tester.getSize(find.byType(PlayButton)), const material_ui.Size(176, 176));

    await tester.tap(find.byType(PlayButton));
    await tester.tap(find.byType(SeekButton).first);
    await tester.tap(find.byType(SeekButton).last);
    await tester.tap(find.byType(FavButton));

    expect(playCalls, 1);
    expect(rewindCalls, 1);
    expect(forwardCalls, 1);
    expect(favoriteCalls, 1);
  });
}
