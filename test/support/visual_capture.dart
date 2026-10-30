import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Use Flutter's cached, licensed Android fonts instead of the test-only Ahem font.
/// No reference-pack media is read or copied by this helper.
Future<void> loadPreviewFonts() async {
  final packages = jsonDecode(File('.dart_tool/package_config.json').readAsStringSync()) as Map;
  final flutter = (packages['packages'] as List).cast<Map>().firstWhere((p) => p['name'] == 'flutter');
  final sdk = Directory.fromUri(Uri.parse(flutter['rootUri'] as String)).parent.parent;
  final fontDirectory = '${sdk.path}/bin/cache/artifacts/material_fonts';
  final text = FontLoader('Roboto');
  for (final name in ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']) {
    final bytes = File('$fontDirectory/$name').readAsBytesSync();
    text.addFont(Future.value(ByteData.sublistView(bytes)));
  }
  await text.load();
  final icons = FontLoader('MaterialIcons');
  icons.addFont(Future.value(ByteData.sublistView(File('$fontDirectory/MaterialIcons-Regular.otf').readAsBytesSync())));
  await icons.load();
}

Future<void> capturePreview(WidgetTester tester, GlobalKey boundary, String name) async {
  await tester.pump();
  await tester.runAsync(() async {
    final render = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('artifacts/phase2a/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}
