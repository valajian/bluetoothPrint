import 'dart:typed_data';

import 'package:bluetooth_order_printer/main.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 用餐方式（堂食 / 打包）+ 桌号 功能验证
/// 覆盖：订单序列化兼容、发票/厨房单顶部标识、备菜汇总单号前缀

Order mkOrder(String no,
        {String diningType = 'dinein', String tableNo = '65'}) =>
    Order(
      id: 'id$no',
      orderNo: no,
      items: [OrderItem(name: '鸡架', price: 10, quantity: 2)],
      total: 20,
      note: '',
      time: DateTime(2026, 9, 11, 12, 30),
      diningType: diningType,
      tableNo: tableNo,
    );

ReceiptSettings mkSettings({String logo = ''}) => ReceiptSettings(
      paperWidth: '80mm',
      storeName: '美味小馆',
      subtitle1: '',
      subtitle2: '',
      footerText: '',
      currency: 'RM',
      phone: '',
      titleFont: 3,
      orderNoFont: 3,
      bodyFont: 0,
      timeLabel: '时间',
      dishLabel: '菜品',
      qtyLabel: '数量',
      priceLabel: '单价',
      subtotalLabel: '小计',
      totalLabel: '合计金额',
      logoBase64: logo,
      logoPrintEnabled: true,
      logoPrintSize: 1,
      showName: true,
      showSubtitle: true,
      qrPrintSize: 0,
    );

/// 把 ESC/POS 字节块解回文本（位图块解出乱码，只用来查关键词）
String chunksToText(List<Uint8List> chunks) {
  final buf = StringBuffer();
  for (final c in chunks) {
    buf.write(gbk.decode(c, allowMalformed: true));
  }
  return buf.toString();
}

String chunkText(Uint8List c) => gbk.decode(c, allowMalformed: true);

/// 1x1 PNG（验证"堂食标识打在招牌图片之前"时需要真实位图才能生成 logo 块）
const _tinyPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

void main() {
  group('Order.diningLabel / diningPrefix', () {
    test('堂食 + 桌号 → 堂食(Table:65)', () {
      final o = mkOrder('001', diningType: 'dinein', tableNo: '65');
      expect(o.diningLabel, '堂食(Table:65)');
      expect(o.diningPrefix, '(堂食)');
      expect(o.isDineIn, true);
    });

    test('堂食未选桌号 → 只打印「堂食」', () {
      final o = mkOrder('001', diningType: 'dinein', tableNo: '');
      expect(o.diningLabel, '堂食');
      expect(o.diningPrefix, '(堂食)');
    });

    test('打包 → 「打包」，桌号不参与打印', () {
      final o = mkOrder('001', diningType: 'takeaway', tableNo: '65');
      expect(o.diningLabel, '打包');
      expect(o.diningPrefix, '(打包)');
    });

    test('旧订单未标记 → 空串（打印时沿用旧格式）', () {
      final o = mkOrder('001', diningType: '', tableNo: '');
      expect(o.diningLabel, '');
      expect(o.diningPrefix, '');
    });
  });

  group('订单序列化', () {
    test('用餐方式与桌号往返不丢', () {
      final o = mkOrder('007', diningType: 'dinein', tableNo: 'A1');
      final back = decodeOrder(encodeOrder(o))!;
      expect(back.diningType, 'dinein');
      expect(back.tableNo, 'A1');
      expect(back.diningLabel, '堂食(Table:A1)');
    });

    test('旧格式 JSON（没有 dt/tn 字段）解码为未标记', () {
      const legacy =
          '{"id":"old1","no":"001","items":[],"total":0,"note":"","time":"2026-09-11T12:30:00.000"}';
      final o = decodeOrder(legacy)!;
      expect(o.diningType, '');
      expect(o.tableNo, '');
      expect(o.diningLabel, '');
      expect(o.diningPrefix, '');
    });
  });

  group('发票（buildEscPosBytesChunks）', () {
    test('堂食带桌号：标识打在最顶部，且在招牌图片之前', () {
      final chunks = buildEscPosBytesChunks(
          mkOrder('001', diningType: 'dinein', tableNo: '65'), mkSettings(logo: _tinyPng));
      // 第一块就是用餐方式
      expect(chunkText(chunks.first), contains('堂食(Table:65)'));
      // 招牌图片块（点阵位图，长度远大于文本块）出现在其后
      final logoIdx = chunks.indexWhere((c) => c.length > 200);
      expect(logoIdx, greaterThan(0));
      expect(chunksToText(chunks), contains('单号：001'));
    });

    test('打包：打印「打包」，不出现「堂食」', () {
      final chunks = buildEscPosBytesChunks(
          mkOrder('002', diningType: 'takeaway', tableNo: ''), mkSettings());
      final text = chunksToText(chunks);
      expect(chunkText(chunks.first), contains('打包'));
      expect(text, isNot(contains('堂食')));
    });

    test('旧订单：不打印用餐方式行', () {
      final chunks = buildEscPosBytesChunks(
          mkOrder('003', diningType: '', tableNo: ''), mkSettings());
      final text = chunksToText(chunks);
      expect(text, isNot(contains('堂食')));
      expect(text, isNot(contains('打包')));
    });

    test('堂食未选桌号：只出现「堂食」，不带 Table 字样', () {
      final chunks = buildEscPosBytesChunks(
          mkOrder('004', diningType: 'dinein', tableNo: ''), mkSettings());
      expect(chunksToText(chunks), contains('堂食'));
      expect(chunksToText(chunks), isNot(contains('Table')));
    });
  });

  group('厨房单（buildKitchenEscPosBytesChunks）', () {
    test('顶部打印堂食桌号', () {
      final chunks = buildKitchenEscPosBytesChunks(
          mkOrder('005', diningType: 'dinein', tableNo: '12'), mkSettings());
      expect(chunksToText(chunks), contains('堂食(Table:12)'));
    });

    test('打包单打印「打包」', () {
      final chunks = buildKitchenEscPosBytesChunks(
          mkOrder('006', diningType: 'takeaway', tableNo: ''), mkSettings());
      expect(chunksToText(chunks), contains('打包'));
    });
  });

  group('备菜汇总（buildPrepSummaryEscPosBytesChunks）', () {
    test('堂食单 → (堂食)订单号<1025>；打包单 → (打包)订单号<1025>', () {
      final dine = buildPrepSummaryEscPosBytesChunks(
          [mkOrder('1025', diningType: 'dinein', tableNo: '65')], mkSettings());
      final dineText = chunksToText(dine);
      expect(dineText, contains('(堂食)订单号<1025>'));

      final take = buildPrepSummaryEscPosBytesChunks(
          [mkOrder('1025', diningType: 'takeaway', tableNo: '')], mkSettings());
      expect(chunksToText(take), contains('(打包)订单号<1025>'));
    });

    test('旧订单未标记 → 沿用旧格式 订单号<1025>（无括号前缀）', () {
      final chunks = buildPrepSummaryEscPosBytesChunks(
          [mkOrder('1025', diningType: '', tableNo: '')], mkSettings());
      final text = chunksToText(chunks);
      expect(text, contains('订单号<1025>'));
      expect(text, isNot(contains('(堂食)订单号')));
      expect(text, isNot(contains('(打包)订单号')));
    });
  });

  group('带用餐方式前缀的备菜明细排版', () {
    Order orderWith(String type, String table) => Order(
          id: 'o1',
          orderNo: '1015',
          items: [
            OrderItem(
                name: '原味鸡翅',
                price: 10,
                quantity: 1,
                catTag: '鸡翅',
                flavorTag: '原味'),
            OrderItem(
                name: '辣味鸡翅',
                price: 10,
                quantity: 2,
                isSpicy: true,
                catTag: '鸡翅',
                flavorTag: '辣味'),
          ],
          total: 30,
          note: '',
          time: DateTime(2026, 9, 11),
          diningType: type,
          tableNo: table,
        );

    test('50mm 堂食：单号行带 (堂食) 前缀，且每行不超宽', () {
      final lines = prepOrderLines(orderWith('dinein', '65'), 32);
      expect(lines.first, startsWith('(堂食)订单号<1015>'));
      for (final l in lines) {
        expect(_w(l), lessThanOrEqualTo(32), reason: '超宽行: "$l"');
      }
    });

    test('50mm 打包：单号行带 (打包) 前缀，且每行不超宽', () {
      final lines = prepOrderLines(orderWith('takeaway', ''), 32);
      expect(lines.first, startsWith('(打包)订单号<1015>'));
      for (final l in lines) {
        expect(_w(l), lessThanOrEqualTo(32), reason: '超宽行: "$l"');
      }
    });

    test('80mm：前缀不把品类明细挤断', () {
      final lines = prepOrderLines(orderWith('dinein', '65'), 48);
      expect(lines.first, contains('(堂食)订单号<1015>'));
      for (final l in lines) {
        expect(_w(l), lessThanOrEqualTo(48), reason: '超宽行: "$l"');
      }
    });
  });

  group('SettingsStore 桌号存储', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('默认空列表，写入后可读回', () async {
      expect(await SettingsStore.getTableNos(), isEmpty);
      await SettingsStore.setTableNos(['1', '65', 'A1']);
      expect(await SettingsStore.getTableNos(), ['1', '65', 'A1']);
    });

    test('改名 / 删除 / 新增后顺序保持', () async {
      await SettingsStore.setTableNos(['1', '2', '3']);
      final list = await SettingsStore.getTableNos();
      list[1] = '20'; // 改
      list.remove('3'); // 删
      list.add('65'); // 增
      await SettingsStore.setTableNos(list);
      expect(await SettingsStore.getTableNos(), ['1', '20', '65']);
    });
  });

  group('界面', () {
    testWidgets('新建订单页：默认堂食且有桌号下拉，切到打包后下拉消失', (tester) async {
      SharedPreferences.setMockInitialValues({'table_nos': ['1', '65']});
      await tester.pumpWidget(const MaterialApp(home: OrderEntryPage()));
      await tester.pumpAndSettle();

      final dineRadio = tester.widget<RadioListTile<String>>(
          find.widgetWithText(RadioListTile<String>, '堂食'));
      final takeRadio = tester.widget<RadioListTile<String>>(
          find.widgetWithText(RadioListTile<String>, '打包'));
      expect(dineRadio.groupValue, 'dinein'); // 默认堂食
      expect(takeRadio.groupValue, 'dinein');
      expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);

      await tester.tap(find.widgetWithText(RadioListTile<String>, '打包'));
      await tester.pumpAndSettle();
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    });

    testWidgets('窄屏手机（360dp）下用餐方式选择器不溢出', (tester) async {
      SharedPreferences.setMockInitialValues({'table_nos': ['1', '65']});
      // 真实手机逻辑尺寸：物理像素 / devicePixelRatio
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: OrderEntryPage()));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
    });

    testWidgets('未收到刷新信号时，看不到设置页刚新增的桌号', (tester) async {
      SharedPreferences.setMockInitialValues({'table_nos': ['1']});
      final signal = ValueNotifier<int>(0);
      addTearDown(signal.dispose);
      await tester.pumpWidget(
          MaterialApp(home: OrderEntryPage(refreshSignal: signal)));
      await tester.pumpAndSettle();

      // 存储里已经有新桌号，但页面没收到刷新信号（IndexedStack 页面常驻）
      await SettingsStore.setTableNos(['1', '65']);
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();

      expect(find.text('1 号桌'), findsWidgets);
      expect(find.text('65 号桌'), findsNothing);
    });

    testWidgets('收到刷新信号后重新读取桌号（设置页增删后能同步）', (tester) async {
      SharedPreferences.setMockInitialValues({'table_nos': ['1']});
      final signal = ValueNotifier<int>(0);
      addTearDown(signal.dispose);
      await tester.pumpWidget(
          MaterialApp(home: OrderEntryPage(refreshSignal: signal)));
      await tester.pumpAndSettle();

      // 模拟在设置页新增了桌号，然后切回新建订单页（MainScreen 会发信号）
      await SettingsStore.setTableNos(['1', '65']);
      signal.value++;
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      expect(find.text('65 号桌'), findsWidgets);
    });

    testWidgets('设置页：显示桌号管理区块与已保存桌号', (tester) async {
      SharedPreferences.setMockInitialValues({'table_nos': ['1', '65']});
      await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
      await tester.pumpAndSettle();

      expect(find.text('桌号管理'), findsOneWidget);
      expect(find.text('新增桌号'), findsOneWidget);
      expect(find.text('1 号桌'), findsOneWidget);
      expect(find.text('65 号桌'), findsOneWidget);
    });
  });
}

/// 半角显示宽度：全角字符按 2 算（和打印排版口径一致）
int _w(String s) {
  var w = 0;
  for (final c in s.codeUnits) {
    w += c > 0xFF ? 2 : 1;
  }
  return w;
}
