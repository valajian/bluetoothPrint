import 'dart:convert';

import 'package:bluetooth_order_printer/main.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 新建订单页「菜品长按排序 + 记忆」验证

String menuJson(String name, double price) =>
    jsonEncode({'n': name, 'p': price, 's': false, 'c': '', 'f': ''});

List<String> namesOf(List<String> raw) =>
    raw.map((s) => (jsonDecode(s) as Map)['n'] as String).toList();

void main() {
  group('菜单顺序持久化（记忆）', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('按存储顺序读出；重排后保存能原样读回', () async {
      await SettingsStore.saveMenu([
        MenuItem(name: 'A', price: 1),
        MenuItem(name: 'B', price: 2),
        MenuItem(name: 'C', price: 3),
      ]);
      expect(
          (await SettingsStore.loadMenu()).map((m) => m.name).toList(),
          ['A', 'B', 'C']);

      // 把 C 提到最前（模拟长按拖拽后的结果）
      final loaded = await SettingsStore.loadMenu();
      await SettingsStore.saveMenu([loaded[2], loaded[0], loaded[1]]);

      // 重新读取（相当于重开 APP）依然是新顺序 → 说明"记住了"
      expect(
          (await SettingsStore.loadMenu()).map((m) => m.name).toList(),
          ['C', 'A', 'B']);
    });

    test('重排不丢菜品属性（价格 / 标签）', () async {
      await SettingsStore.saveMenu([
        MenuItem(name: '原味鸡架', price: 12.5, catTag: '鸡架', flavorTag: '原味'),
        MenuItem(name: '辣味鸡架', price: 13, catTag: '鸡架', flavorTag: '辣味'),
      ]);
      final loaded = await SettingsStore.loadMenu();
      await SettingsStore.saveMenu([loaded[1], loaded[0]]);

      final again = await SettingsStore.loadMenu();
      expect(again.map((m) => m.name).toList(), ['辣味鸡架', '原味鸡架']);
      expect(again.first.catTag, '鸡架');
      expect(again.first.flavorTag, '辣味');
      expect(again.first.price, 13);
    });
  });

  group('新建订单页菜品排序', () {
    /// 用手机尺寸：测试默认窗口 800x600 会被判定为平板，走网格布局
    void usePhoneScreen(WidgetTester tester) {
      tester.view.physicalSize = const Size(400, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    testWidgets('菜单是可拖动列表：长按拖动后顺序变化并被保存', (tester) async {
      SharedPreferences.setMockInitialValues({
        'menu_items': [menuJson('A', 1), menuJson('B', 2), menuJson('C', 3)],
      });
      usePhoneScreen(tester);
      await tester.pumpWidget(const MaterialApp(home: OrderEntryPage()));
      await tester.pumpAndSettle();

      expect(find.byType(ReorderableListView), findsOneWidget);
      final tiles = find.descendant(
          of: find.byType(ReorderableListView), matching: find.byType(ListTile));
      expect(tiles, findsNWidgets(3));

      // 坐标要在拖拽前取：拖拽开始后被拖的项会移出列表（进入 overlay）
      final start = tester.getCenter(tiles.first);
      final target = tester.getCenter(tiles.at(2));

      // 长按第一项（模拟 ReorderableDelayedDragStartListener）并拖到第 3 项位置
      final gesture = await tester.startGesture(start);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await gesture.moveTo(target);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      // 1) 顺序被写进本地（这就是"记忆"）
      final saved =
          (await SharedPreferences.getInstance()).getStringList('menu_items')!;
      final names = namesOf(saved);
      expect(names, containsAll(['A', 'B', 'C']));
      expect(names.first, isNot('A'), reason: 'A 应被拖到了后面');

      // 2) 界面顺序跟着变
      final firstTitle = tester
          .widget<ListTile>(find
              .descendant(
                  of: find.byType(ReorderableListView),
                  matching: find.byType(ListTile))
              .first)
          .title as Text;
      expect(firstTitle.data, isNot('A'));
    });

    testWidgets('平板网格：长按菜品弹出排序对话框', (tester) async {
      SharedPreferences.setMockInitialValues({
        'menu_items': [menuJson('A', 1), menuJson('B', 2), menuJson('C', 3)],
      });
      tester.view.physicalSize = const Size(1200, 800); // 横屏平板
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: OrderEntryPage()));
      await tester.pumpAndSettle();

      expect(find.byType(GridView), findsOneWidget); // 平板走网格
      await tester.longPress(find.text('A'));
      await tester.pumpAndSettle();

      expect(find.text('调整菜品顺序'), findsOneWidget);
      expect(find.byType(ReorderableListView), findsOneWidget); // 对话框内可拖动
    });

    testWidgets('拖动后重新进入页面仍是新顺序（记忆生效）', (tester) async {
      SharedPreferences.setMockInitialValues({
        'menu_items': [menuJson('A', 1), menuJson('B', 2), menuJson('C', 3)],
      });
      usePhoneScreen(tester);
      await tester.pumpWidget(const MaterialApp(home: OrderEntryPage()));
      await tester.pumpAndSettle();

      final tiles = find.descendant(
          of: find.byType(ReorderableListView), matching: find.byType(ListTile));
      final start = tester.getCenter(tiles.first);
      final target = tester.getCenter(tiles.at(2));
      final gesture = await tester.startGesture(start);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await gesture.moveTo(target);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      final saved =
          (await SharedPreferences.getInstance()).getStringList('menu_items')!;
      final expected = namesOf(saved);

      // 重建页面（相当于切走再切回 / 重开 APP）
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      usePhoneScreen(tester);
      await tester.pumpWidget(const MaterialApp(home: OrderEntryPage()));
      await tester.pumpAndSettle();

      final shown = tester
          .widgetList<ListTile>(find.descendant(
              of: find.byType(ReorderableListView),
              matching: find.byType(ListTile)))
          .map((t) => (t.title as Text).data)
          .toList();
      expect(shown, expected);
    });
  });
}
