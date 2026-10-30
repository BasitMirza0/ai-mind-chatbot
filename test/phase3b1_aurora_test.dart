import 'package:ai_chatbot/controllers/chat_controller.dart';
import 'package:ai_chatbot/controllers/voice_controller.dart';
import 'package:ai_chatbot/screens/voice_screen.dart';
import 'package:ai_chatbot/services/speech_coordinator.dart';
import 'package:ai_chatbot/theme/app_theme.dart';
import 'package:ai_chatbot/widgets/voice_visualization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/fake_chat_dependencies.dart';
import 'support/fake_voice_dependencies.dart';
import 'support/visual_capture.dart';

void main() {
  test('continuous phase and bounded derivatives through every state', () {
    final motion = AuroraMotion(VoicePhase.idle);
    addTearDown(motion.dispose);
    for (var cycle = 0; cycle < 5; cycle++) {
      for (final phase in VoicePhase.values) {
        final before = motion.angle;
        motion.targetPhase(phase);
        expect(motion.angle, before);
        for (var frame = 0; frame < 180; frame++) {
          final angle = motion.angle;
          final energy = motion.energy;
          final speed = motion.speed;
          motion.advance(1 / 60);
          expect(motion.angle, greaterThanOrEqualTo(angle));
          expect(motion.angle - angle, lessThan(.025));
          expect((motion.energy - energy).abs(), lessThan(.08));
          expect((motion.speed - speed).abs(), lessThan(.18));
        }
      }
    }
    motion.targetPhase(VoicePhase.speaking);
    for (var i = 0; i < 180; i++) {
      motion.advance(1 / 60);
    }
    final beforeStall = motion.angle;
    motion.advance(60);
    expect(motion.angle - beforeStall, lessThan(.05));
  });

  test(
    'Start Talking has one eased activation then stays still until playback',
    () {
      final motion = AuroraMotion(VoicePhase.idle);
      addTearDown(motion.dispose);
      expect(motion.settled, isTrue);
      motion.targetPhase(VoicePhase.initializing);
      for (var i = 0; i < 15; i++) {
        motion.advance(1 / 60);
      }
      final halfway = motion.angle;
      expect(halfway, greaterThan(0));
      motion.targetPhase(VoicePhase.listening);
      for (var i = 0; i < 100; i++) {
        motion.advance(1 / 60);
      }
      expect(motion.angle, closeTo(.65, .00001));
      expect(motion.settled, isTrue);
      final end = motion.angle;
      for (var i = 0; i < 600; i++) {
        motion.advance(1 / 60);
      }
      expect(motion.angle, end);
      motion.targetPhase(VoicePhase.processing);
      for (var i = 0; i < 100; i++) {
        motion.advance(1 / 60);
      }
      expect(motion.angle, end);
      expect(motion.settled, isTrue);
    },
  );

  testWidgets(
    'one motion owner survives rebuilds, stops offscreen and resumes without phase reset',
    (t) async {
      Widget app(
        VoicePhase phase, {
        bool enabled = true,
        bool reduced = false,
      }) => MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: TickerMode(
            enabled: enabled,
            child: Center(child: VoiceVisualization(phase: phase)),
          ),
        ),
      );
      AuroraMotion motion() =>
          (t
                      .widgetList<CustomPaint>(find.byType(CustomPaint))
                      .firstWhere((w) => w.painter is AuroraOrbPainter)
                      .painter!
                  as AuroraOrbPainter)
              .motion;
      await t.pumpWidget(app(VoicePhase.speaking));
      await t.pump(const Duration(milliseconds: 16));
      final owner = motion();
      for (var i = 0; i < 15; i++) {
        await t.pump(const Duration(milliseconds: 16));
      }
      final before = owner.angle;
      await t.pumpWidget(app(VoicePhase.listening));
      expect(identical(owner, motion()), isTrue);
      expect(owner.angle, before);
      await t.pump(const Duration(milliseconds: 16));
      expect(owner.angle, greaterThan(before));
      await t.pumpWidget(app(VoicePhase.speaking, enabled: false));
      final hidden = owner.angle;
      await t.pump(const Duration(seconds: 30));
      expect(owner.angle, hidden);
      expect(t.hasRunningAnimations, isFalse);
      await t.pumpWidget(app(VoicePhase.speaking));
      await t.pump(const Duration(milliseconds: 16));
      expect(owner.angle - hidden, lessThan(.02));
      await t.pumpWidget(app(VoicePhase.speaking, reduced: true));
      final reduced = owner.angle;
      await t.pump(const Duration(seconds: 10));
      expect(owner.angle, reduced);
      expect(t.hasRunningAnimations, isFalse);
      await t.pumpWidget(app(VoicePhase.speaking));
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final background = owner.angle;
      await t.pump(const Duration(seconds: 30));
      expect(owner.angle, background);
      expect(t.hasRunningAnimations, isFalse);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pump(const Duration(milliseconds: 16));
      expect(owner.angle - background, lessThan(.02));
      await t.pumpWidget(app(VoicePhase.paused));
      for (var i = 0; i < 120; i++) {
        await t.pump(const Duration(milliseconds: 16));
      }
      expect(t.hasRunningAnimations, isFalse);
      expect(owner.angle, greaterThan(0));
      await t.pumpWidget(const SizedBox());
      expect(t.takeException(), isNull);
      expect(t.hasRunningAnimations, isFalse);
    },
  );

  testWidgets('state label fades through without two visible headings', (
    t,
  ) async {
    final f = _Fixture();
    addTearDown(f.dispose);
    await t.pumpWidget(f.app(reduced: false));
    await f.voice.begin();
    await t.pump();
    expect(find.byKey(const Key('voice-state-label')), findsOneWidget);
    for (final step in [50, 50, 50, 70]) {
      await t.pump(Duration(milliseconds: step));
      final transitions = t.widgetList<FadeTransition>(
        find.descendant(
          of: find.byKey(const Key('voice-state-label')),
          matching: find.byType(FadeTransition),
        ),
      );
      expect(transitions, isNotEmpty);
      expect(
        transitions.where((w) => w.opacity.value > .01).length,
        lessThanOrEqualTo(1),
      );
    }
    expect(find.text('Listening…'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets(
    'continuous motion starts only at native playback and stops at completion',
    (t) async {
      final output = _DelayedPlayback();
      final f = _Fixture(speechOutput: output);
      addTearDown(f.dispose);
      await t.pumpWidget(f.app(reduced: false));
      await t.pumpAndSettle();
      final center = t.getCenter(find.byType(VoiceVisualization));
      expect(t.hasRunningAnimations, isFalse);
      await f.voice.begin();
      await t.pumpAndSettle();
      expect(f.voice.phase, VoicePhase.listening);
      expect(t.hasRunningAnimations, isFalse);
      expect(
        (t.getCenter(find.byType(VoiceVisualization)) - center).distance,
        lessThan(.5),
      );
      f.driver.result!(const SpeechText('What is Flutter?', true));
      await t.pumpAndSettle();
      expect(f.voice.phase, VoicePhase.processing);
      expect(t.hasRunningAnimations, isFalse);
      f.ai.streams.single.add('Flutter is a toolkit.');
      await f.ai.streams.single.close();
      await t.pumpAndSettle();
      // Having a completed answer is not the same as audible playback starting.
      expect(f.voice.phase, VoicePhase.processing);
      expect(t.hasRunningAnimations, isFalse);
      output.nativeStart!();
      await t.pump();
      for (var i = 0; i < 30; i++) {
        await t.pump(const Duration(milliseconds: 16));
      }
      expect(f.voice.phase, VoicePhase.speaking);
      expect(t.hasRunningAnimations, isTrue);
      output.complete();
      await t.pumpAndSettle();
      expect(f.voice.phase, VoicePhase.idle);
      expect(t.hasRunningAnimations, isFalse);
      await t.pumpWidget(const SizedBox());
    },
  );

  setUpAll(loadPreviewFonts);
  for (final width in [320.0, 360.0, 393.0, 430.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'Aurora Voice fits $width at $scale including keyboard, long text and controls',
        (t) async {
          t.view.devicePixelRatio = 1;
          t.view.physicalSize = Size(width, 640);
          addTearDown(t.view.resetPhysicalSize);
          addTearDown(t.view.resetDevicePixelRatio);
          addTearDown(t.view.resetViewInsets);
          final fixture = _Fixture();
          addTearDown(fixture.dispose);
          await t.pumpWidget(fixture.app(scale: scale));
          await t.pumpAndSettle();
          await t.ensureVisible(find.byKey(const Key('voice-primary')));
          await t.tap(find.text('Start talking'));
          await t.pumpAndSettle();
          fixture.driver.result!(
            SpeechText('A question with ${'verylongunbrokenword' * 25}', false),
          );
          await t.pumpAndSettle();
          expect(t.takeException(), isNull);
          await t.ensureVisible(find.text('Send'));
          await t.tap(find.text('Send'));
          await t.pumpAndSettle();
          fixture.ai.streams.single.add('A detailed answer. ' * 150);
          await t.pumpAndSettle();
          expect(t.takeException(), isNull);
          // Scroll up inside a growing reply: subsequent chunks must not force
          // the reader back to the bottom.
          final panel = find.byKey(const Key('voice-transcript-panel'));
          final scrollable =
              find
                  .descendant(of: panel, matching: find.byType(Scrollable))
                  .first;
          final position = t.state<ScrollableState>(scrollable).position;
          position.jumpTo(0);
          fixture.ai.streams.single.add('Another paragraph. ' * 10);
          await t.pumpAndSettle();
          expect(position.pixels, 0);
          t.view.viewInsets = const FakeViewPadding(bottom: 280);
          await t.pumpAndSettle();
          await t.ensureVisible(find.text('Stop'));
          await t.tap(find.text('Stop'));
          await t.pumpAndSettle();
          expect(fixture.voice.phase, VoicePhase.paused);
          expect(t.takeException(), isNull);
          await t.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets('capture rendered major states and repeated turn continuity', (
    t,
  ) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(393, 852);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final f = _Fixture();
    addTearDown(f.dispose);
    final boundary = GlobalKey();
    await t.pumpWidget(RepaintBoundary(key: boundary, child: f.app()));
    await t.pumpAndSettle();
    Future<void> capture(String name) =>
        capturePreview(t, boundary, '../phase3b1/rendered_$name');
    await capture('ready_393');
    await t.tap(find.text('Start talking'));
    await t.pumpAndSettle();
    f.driver.result!(
      const SpeechText('How can I make room for a creative habit?', false),
    );
    await t.pumpAndSettle();
    await capture('listening_393');
    f.driver.result!(
      const SpeechText('How can I make room for a creative habit?', true),
    );
    await t.pumpAndSettle();
    await capture('thinking_393');
    f.ai.streams.single.add(
      'Start with ten quiet minutes. Choose something you enjoy, keep your materials close, and let a small daily practice be enough.',
    );
    await f.ai.streams.single.close();
    await t.pumpAndSettle();
    await capture('speaking_393');
    await t.tap(find.text('Stop'));
    await t.pumpAndSettle();
    await capture('stopped_393');
    expect(f.output.stops, greaterThan(0));
    await t.tap(find.text('Start talking'));
    await t.pumpAndSettle();
    expect(f.driver.listens, 2);
    expect(f.ai.histories.length, 1);
    await t.pumpWidget(const SizedBox());
  });
}

class _Fixture {
  final session = FakeSession();
  final ai = FakeAi();
  final driver = FakeSpeechDriver();
  final FakeSpeechOutput output;
  _Fixture({FakeSpeechOutput? speechOutput})
    : output = speechOutput ?? FakeSpeechOutput();
  late final chat = ChatController(
    ai: ai,
    repository: FakeRepository(),
    currentUid: () => session.uid,
  );
  late final voice = VoiceController(
    chat: chat,
    speech: SpeechCoordinator(driver),
    output: output,
    currentUid: () => session.uid,
  );
  Widget app({double scale = 1, bool reduced = true}) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light,
    builder:
        (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: reduced,
            textScaler: TextScaler.linear(scale),
            padding: const EdgeInsets.only(top: 24, bottom: 24),
          ),
          child: child!,
        ),
    home: VoiceScreen(session: session, controller: voice),
  );
  void dispose() {
    voice.dispose();
    chat.dispose();
    session.dispose();
    ai.close();
  }
}

class _DelayedPlayback extends FakeSpeechOutput {
  VoidCallback? nativeStart;
  @override
  Future<void> speak(
    Object owner,
    String text, {
    String? locale,
    VoidCallback? onStart,
  }) {
    nativeStart = onStart;
    return super.speak(owner, text, locale: locale);
  }
}
