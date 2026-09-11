import 'dart:typed_data';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bluetooth_order_printer/main.dart';

OrderItem mkItem(String name, String cat, String flavor, int qty) => OrderItem(
      name: name,
      price: 10,
      quantity: qty,
      isSpicy: flavor == '辣味',
      catTag: cat,
      flavorTag: flavor,
    );

/// 这些用例关注备菜汇总的排版基线，用餐方式用"未标记"（旧订单）避免干扰；
/// 堂食/打包前缀的排版见 dining_test.dart
Order mkOrder(String no, List<OrderItem> items) => Order(
      id: 'id$no',
      orderNo: no,
      items: items,
      total: 0,
      note: '',
      time: DateTime(2026, 9, 10),
      diningType: '',
    );

const _s50 = ReceiptSettings(
  paperWidth: '50mm',
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
);

/// 把打印字节流解回可读文本（剥掉 ESC/POS 控制序列），按行返回
List<String> renderLines(List<Uint8List> chunks) {
  final raw = chunks.map((c) => gbk.decode(c)).join();
  final clean = raw
      .replaceAll('\x1B\x40', '') // ESC @ 初始化
      .replaceAll('\x1D\x21\x01', '') // GS ! 1x2
      .replaceAll('\x1D\x21\x00', '') // GS ! 1x1
      .replaceAll('\x1B\x61\x01', '') // ESC a 居中
      .replaceAll('\x1B\x61\x00', '') // ESC a 左对齐
      .replaceAll('\x1B\x64\x05', ''); // ESC d 走纸
  return clean.split('\n').where((l) => l.trim().isNotEmpty).toList();
}

void main() {
  test('50mm 备菜汇总单：上半汇总 + 下半逐单（直接解码打印字节核对）', () {
    final orders = [
      mkOrder('0015', [
        mkItem('原味鸡翅', '鸡翅', '原味', 1),
        mkItem('辣味鸡翅', '鸡翅', '辣味', 2),
        mkItem('辣味鸡架', '鸡架', '辣味', 2),
      ]),
      mkOrder('0016', [
        mkItem('原味鸡架', '鸡架', '原味', 3),
        mkItem('沙田鸡', '沙田鸡', '', 1),
      ]),
    ];

    final lines = renderLines(buildPrepSummaryEscPosBytesChunks(orders, _s50));

    // ignore: avoid_print
    print('----- 实际打印内容（50mm）-----\n${lines.join('\n')}\n----- 结束 -----');

    // ===== 上半部分：按品类合计，辣为 0 也打 =====
    expect(lines, contains('[鸡架] 共 5'));
    expect(lines, contains('  不辣 x 3'));
    expect(lines, contains('  辣 x 2'));
    expect(lines, contains('[鸡翅] 共 3'));
    expect(lines, contains('  不辣 x 1'));
    expect(lines, contains('  辣 x 2'));
    expect(lines, contains('[沙田鸡] 共 1'));
    expect(lines, contains('  不辣 x 1'));
    expect(lines, contains('  辣 x 0'));

    // 汇总按总份数降序：鸡架 5 > 鸡翅 3 > 沙田鸡 1
    final iChickenBone = lines.indexWhere((l) => l.startsWith('[鸡架]'));
    final iWing = lines.indexWhere((l) => l.startsWith('[鸡翅]'));
    final iShantian = lines.indexWhere((l) => l.startsWith('[沙田鸡]'));
    expect(iChickenBone, lessThan(iWing));
    expect(iWing, lessThan(iShantian));

    // ===== 下半部分：逐单明细 =====
    expect(lines, contains('订单号<0015>'));
    expect(lines, contains('      [鸡翅] 辣 x 2, 不辣 x 1'));
    expect(lines, contains('      [鸡架] 辣 x 2'));
    expect(lines, contains('订单号<0016>, [鸡架] 不辣 x 3'));
    expect(lines, contains('      [沙田鸡] x 1'));

    // ===== 汇总必须排在逐单之前 =====
    final iFirstOrder = lines.indexWhere((l) => l.startsWith('订单号<'));
    expect(iShantian, lessThan(iFirstOrder));

    // ===== 逐单按传入顺序（1015 在 1016 前）=====
    final orderIdx = <int>[];
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].startsWith('订单号<')) orderIdx.add(i);
    }
    expect(lines[orderIdx[0]], contains('0015'));
    expect(lines[orderIdx[1]], contains('0016'));

    // ===== 没有一行超宽（50mm = 32 半角字符）=====
    for (final l in lines) {
      expect(_w(l), lessThanOrEqualTo(32), reason: '超宽行: "$l"');
    }
  });

  test('80mm 备菜汇总单：更宽所以明细能多塞一个品类', () {
    const s80 = ReceiptSettings(
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
    );

    final orders = [
      mkOrder('0015', [
        mkItem('原味鸡翅', '鸡翅', '原味', 1),
        mkItem('辣味鸡翅', '鸡翅', '辣味', 2),
        mkItem('辣味鸡架', '鸡架', '辣味', 2),
      ]),
    ];

    final lines = renderLines(buildPrepSummaryEscPosBytesChunks(orders, s80));
    // ignore: avoid_print
    print('----- 实际打印内容（80mm）-----\n${lines.join('\n')}\n----- 结束 -----');

    expect(lines, contains('订单号<0015>, [鸡翅] 辣 x 2, 不辣 x 1'));
    expect(lines, contains('      [鸡架] 辣 x 2'));

    for (final l in lines) {
      expect(_w(l), lessThanOrEqualTo(48), reason: '超宽行: "$l"');
    }
  });
}

/// 半角显示宽度：全角字符按 2 算（和打印排版用的口径一致）
int _w(String s) {
  var w = 0;
  for (final c in s.codeUnits) {
    w += c > 0xFF ? 2 : 1;
  }
  return w;
}
