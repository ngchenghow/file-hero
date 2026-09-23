import 'package:flutter_test/flutter_test.dart';
import 'package:file_hero/main.dart';

void main() {
  testWidgets('starts disconnected and explains USB access', (tester) async {
    await tester.pumpWidget(const FileHeroApp());
    expect(find.text('file-hero'), findsOneWidget);
    expect(find.textContaining('点击右上角 USB'), findsOneWidget);
  });
}
