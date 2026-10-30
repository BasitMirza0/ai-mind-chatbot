import 'package:ai_chatbot/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('AI Mind opens the real first-run introduction', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MyApp(isLoggedIn: false));
    await tester.pumpAndSettle();
    expect(find.text('A clearer mind,\none chat away.'), findsOneWidget);
    expect(find.text('AI features require sign-in.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
