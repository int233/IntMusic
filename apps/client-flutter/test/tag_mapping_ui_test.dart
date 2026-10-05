import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intmusic_client/intmusic_client.dart';

Map<String, dynamic> settings([List<Map<String, dynamic>> rules = const []]) =>
    {
      'artist_separators': [';'],
      'genre_separators': ['|'],
      'tag_mappings': rules,
    };

Map<String, dynamic> rule({List<String> fields = const ['genres']}) => {
  'source': '我的原始标签',
  'targets': ['我的输出'],
  'fields': fields,
};

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Finder output(int number) => find.byWidgetPredicate(
  (widget) =>
      widget is TextField && widget.decoration?.labelText == '输出标签 $number',
);

void main() {
  testWidgets(
    'users author one to five outputs and select target fields on phone and desktop',
    (tester) async {
      for (final width in [390.0, 1200.0]) {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        Map<String, dynamic>? saved;
        var applied = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: tagRulesForTesting(
                settings: settings(),
                onSave: (value) async {
                  saved = value;
                  return true;
                },
                onApply: () async {
                  applied++;
                },
              ),
            ),
          ),
        );
        expect(find.text('暂无映射规则，不会自动拆分复合标签。'), findsOneWidget);
        await tapVisible(tester, find.text('添加映射规则'));
        await tester.enterText(
          find.byKey(const ValueKey('mapping-source-0')),
          '自定义组合',
        );
        await tester.enterText(output(1), '输出一');
        await tapVisible(tester, find.widgetWithText(FilterChip, '流派'));
        await tapVisible(tester, find.text('保存规则'));
        expect(saved?['tag_mappings'], [
          {
            'source': '自定义组合',
            'targets': ['输出一'],
            'fields': ['genres'],
          },
        ]);
        expect(applied, 0);
        for (var count = 1; count < 5; count++) {
          await tapVisible(tester, find.text('添加输出标签（$count/5）'));
          await tester.enterText(output(count + 1), '标签${count + 1}');
        }
        final fullButton = tester.widget<TextButton>(
          find.widgetWithText(TextButton, '添加输出标签（5/5）'),
        );
        expect(fullButton.onPressed, isNull);
        await tapVisible(tester, find.widgetWithText(FilterChip, '作曲'));
        await tapVisible(tester, find.text('保存并应用到已有资料'));
        expect((saved?['tag_mappings'] as List).single, {
          'source': '自定义组合',
          'targets': ['输出一', '标签2', '标签3', '标签4', '标签5'],
          'fields': ['genres', 'composers'],
        });
        expect(applied, 1);
        // Removing a focused output and rule must not leave a disposed controller in use.
        await tester.ensureVisible(output(5));
        await tester.tap(output(5));
        await tapVisible(tester, find.byTooltip('删除输出标签').last);
        expect(output(5), findsNothing);
        await tapVisible(tester, find.byTooltip('删除规则'));
        await tapVisible(tester, find.text('保存规则'));
        expect(saved?['tag_mappings'], isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    },
  );

  testWidgets(
    'field selection and duplicate targets are validated before saving',
    (tester) async {
      var saves = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: tagRulesForTesting(
              settings: settings([rule(fields: [])]),
              onSave: (_) async {
                saves++;
                return true;
              },
              onApply: () async {},
            ),
          ),
        ),
      );
      await tapVisible(tester, find.text('保存规则'));
      expect(saves, 0);
      expect(find.text('请为每条规则选择至少一个应用字段'), findsOneWidget);
      await tapVisible(tester, find.widgetWithText(FilterChip, '流派'));
      await tapVisible(tester, find.text('添加输出标签（1/5）'));
      await tester.enterText(output(2), '我的输出');
      await tapVisible(tester, find.text('保存规则'));
      expect(saves, 0);
      expect(find.text('同一规则的输出标签不能重复'), findsOneWidget);
    },
  );

  testWidgets(
    'save failure blocks applying and remote refresh preserves unfinished edits',
    (tester) async {
      var applied = 0;
      late StateSetter rebuild;
      var remote = settings([rule()]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return tagRulesForTesting(
                  settings: remote,
                  onSave: (_) async => false,
                  onApply: () async {
                    applied++;
                  },
                );
              },
            ),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('mapping-source-0')),
        '正在编辑',
      );
      rebuild(() => remote = settings());
      await tester.pumpAndSettle();
      expect(find.text('正在编辑'), findsOneWidget);
      await tapVisible(tester, find.text('保存并应用到已有资料'));
      expect(applied, 0);
      expect(find.text('保存失败，规则尚未应用，请重试。'), findsOneWidget);
      expect(find.text('正在编辑'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
