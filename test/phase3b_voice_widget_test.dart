import 'dart:async';
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

void main() {
  late FakeSession session;
  late FakeAi ai;
  late FakeSpeechDriver driver;
  late FakeSpeechOutput output;
  late ChatController chat;
  late VoiceController voice;
  void create() {
    session = FakeSession();
    ai = FakeAi();
    driver = FakeSpeechDriver();
    output = FakeSpeechOutput();
    chat = ChatController(
      ai: ai,
      repository: FakeRepository(),
      currentUid: () => session.uid,
    );
    voice = VoiceController(
      chat: chat,
      speech: SpeechCoordinator(driver),
      output: output,
      currentUid: () => session.uid,
    );
  }

  tearDown(() async {
    voice.dispose();
    chat.dispose();
    session.dispose();
    await ai.close();
  });
  Widget app({double scale = 1}) => MaterialApp(
    theme: AppTheme.light,
    builder:
        (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: true,
            textScaler: TextScaler.linear(scale),
          ),
          child: child!,
        ),
    home: VoiceScreen(session: session, controller: voice),
  );
  testWidgets(
    'permission dialog inactive state does not cancel first initialization; background does',
    (tester) async {
      create();
      driver.permissionGate = Completer();
      await tester.pumpWidget(app());
      await tester.tap(find.text('Start talking'));
      await tester.pumpAndSettle();
      expect(voice.phase, VoicePhase.initializing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(voice.phase, VoicePhase.initializing);
      driver.permissionGate!.complete(true);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(voice.phase, VoicePhase.listening);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      expect(voice.phase, VoicePhase.paused);
      expect(driver.listens, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(driver.listens, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'actual controller states drive the visual and return to Ready without auto listening',
    (tester) async {
      create();
      await tester.pumpWidget(app());
      await tester.tap(find.text('Start talking'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<VoiceVisualization>(find.byType(VoiceVisualization))
            .phase,
        VoicePhase.listening,
      );
      driver.result!(const SpeechText('What is Flutter?', false));
      await tester.pump();
      expect(find.text('What is Flutter?'), findsOneWidget);
      driver.result!(const SpeechText('What is Flutter?', true));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<VoiceVisualization>(find.byType(VoiceVisualization))
            .phase,
        VoicePhase.processing,
      );
      ai.streams.single.add('Flutter is a toolkit.');
      await ai.streams.single.close();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<VoiceVisualization>(find.byType(VoiceVisualization))
            .phase,
        VoicePhase.speaking,
      );
      expect(find.text('New turn'), findsOneWidget);
      output.complete();
      await tester.pumpAndSettle();
      expect(voice.phase, VoicePhase.idle);
      expect(driver.listens, 1);
      expect(find.text('Read again'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final width in [320.0, 360.0, 393.0, 430.0]) {
    testWidgets('voice errors and controls fit $width at large text', (
      tester,
    ) async {
      create();
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      driver.initializationError = const SpeechInputFailure(
        'permission_permanently_denied',
      );
      await tester.pumpWidget(app(scale: 2));
      await voice.begin();
      await tester.pumpAndSettle();
      expect(find.text('Open Android settings'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets(
    'navigation during processing cancels and late callbacks cannot update disposed screen',
    (tester) async {
      create();
      await tester.pumpWidget(app());
      await tester.tap(find.text('Start talking'));
      await tester.pumpAndSettle();
      driver.result!(const SpeechText('Question', true));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      ai.streams.single.add('Late answer');
      await tester.pump();
      expect(voice.phase, VoicePhase.paused);
      expect(output.spoken, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
