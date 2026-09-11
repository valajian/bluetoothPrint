import 'package:flutter_test/flutter_test.dart';
import 'package:bluetooth_order_printer/main.dart';

/// 造一条订单明细（isSpicy 按口味标签是否为"辣味"来定）
OrderItem mkItem(String name, String cat, String flavor, int qty) => OrderItem(
      name: name,
      price: 10,
      quantity: qty,
      isSpicy: flavor == '辣味',
      catTag: cat,
      flavorTag: flavor,
    );

/// 这些用例关注备菜聚合与排版基线，用餐方式用"未标记"（旧订单）避免干扰；
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

void main() {
  // ============ 上半部分：按品类合计 ============

  test('同一品类的原味与辣味合并成一组，辣/不辣各自计数', () {
    final orders = [
      mkOrder('001', [
        mkItem('原味鸡架', '鸡架', '原味', 2),
        mkItem('辣味鸡架', '鸡架', '辣味', 1),
      ]),
      mkOrder('002', [
        mkItem('辣味鸡架', '鸡架', '辣味', 3),
        mkItem('鸡翅', '鸡翅', '原味', 2),
      ]),
    ];

    final groups = aggregatePrep(orders);

    // 鸡架 6 份 > 鸡翅 2 份，排前面
    expect(groups.first.name, '鸡架');
    expect(groups.first.total, 6);
    expect(groups.first.plainQty, 2);
    expect(groups.first.spicyQty, 4);
    expect(groups.first.byCategory, isTrue);
  });

  test('汇总固定三行：共 / 不辣 / 辣，辣为 0 也照打', () {
    final groups = aggregatePrep([
      mkOrder('001', [mkItem('原味鸡架', '鸡架', '原味', 3)]),
    ]);

    expect(prepGroupLines(groups.first), ['[鸡架] 共 3', '  不辣 x 3', '  辣 x 0']);
  });

  test('没挂品类标签的菜按菜名单独成组，单行显示', () {
    final groups = aggregatePrep([
      mkOrder('001', [mkItem('矿泉水', '', '', 2)]),
    ]);

    expect(groups.length, 1);
    expect(groups.first.byCategory, isFalse);
    expect(prepGroupLines(groups.first), ['矿泉水 x 2']);
  });

  test('菜名与品类标签同名时不会被误合并', () {
    final groups = aggregatePrep([
      mkOrder('001', [
        mkItem('原味鸡架', '鸡架', '原味', 1),
        mkItem('鸡架', '', '', 2),
      ]),
    ]);

    expect(groups.length, 2);
    final tagged = groups.firstWhere((g) => g.byCategory);
    final plain = groups.firstWhere((g) => !g.byCategory);
    expect(tagged.total, 1);
    expect(plain.total, 2);
  });

  // ============ 下半部分：逐单明细 ============

  test('逐单明细：辣与不辣并存时都列出来', () {
    final o = mkOrder('1015', [
      mkItem('原味鸡翅', '鸡翅', '原味', 1),
      mkItem('辣味鸡翅', '鸡翅', '辣味', 2),
      mkItem('辣味鸡架', '鸡架', '辣味', 2),
    ]);

    expect(prepOrderLines(o, 999), [
      '订单号<1015>, [鸡翅] 辣 x 2, 不辣 x 1, [鸡架] 辣 x 2',
    ]);
  });

  test('逐单明细：50mm 纸宽放不下时在品类边界换行，不劈开品类名', () {
    final o = mkOrder('1015', [
      mkItem('原味鸡翅', '鸡翅', '原味', 1),
      mkItem('辣味鸡翅', '鸡翅', '辣味', 2),
      mkItem('辣味鸡架', '鸡架', '辣味', 2),
    ]);

    expect(prepOrderLines(o, 32), [
      '订单号<1015>',
      '      [鸡翅] 辣 x 2, 不辣 x 1',
      '      [鸡架] 辣 x 2',
    ]);
  });

  test('逐单明细：放得下时单号与品类同行，只有不辣时不写"辣 x 0"', () {
    final o = mkOrder('1016', [mkItem('原味鸡架', '鸡架', '原味', 3)]);

    expect(prepOrderLines(o, 32), ['订单号<1016>, [鸡架] 不辣 x 3']);
  });

  test('逐单明细：该品类没标过口味时只写总量', () {
    final o = mkOrder('1016', [mkItem('沙田鸡', '沙田鸡', '', 1)]);

    expect(prepOrderLines(o, 32), ['订单号<1016>, [沙田鸡] x 1']);
  });

  test('逐单明细：没有品类标签的菜用菜名当方括号名', () {
    final o = mkOrder('1017', [mkItem('矿泉水', '', '', 2)]);

    expect(prepOrderLines(o, 32), ['订单号<1017>, [矿泉水] x 2']);
  });

  // ============ 整单排版 ============

  test('整单排版：上半汇总按份数降序，下半逐单按传入顺序', () {
    final orders = [
      mkOrder('1015', [
        mkItem('原味鸡翅', '鸡翅', '原味', 1),
        mkItem('辣味鸡翅', '鸡翅', '辣味', 2),
      ]),
      mkOrder('1016', [
        mkItem('原味鸡架', '鸡架', '原味', 4),
        mkItem('沙田鸡', '沙田鸡', '', 1),
      ]),
    ];

    // 上半：鸡架 4 > 鸡翅 3 > 沙田鸡 1
    final groups = aggregatePrep(orders);
    expect(groups.map((g) => g.name).toList(), ['鸡架', '鸡翅', '沙田鸡']);
    expect(groups.firstWhere((g) => g.name == '鸡翅').spicyQty, 2);
    expect(groups.firstWhere((g) => g.name == '鸡翅').plainQty, 1);

    // 下半：逐单
    expect(prepOrderLines(orders[0], 32), [
      '订单号<1015>',
      '      [鸡翅] 辣 x 2, 不辣 x 1',
    ]);
    expect(prepOrderLines(orders[1], 32), [
      '订单号<1016>, [鸡架] 不辣 x 4',
      '      [沙田鸡] x 1',
    ]);
  });

  // ============ 无辣单判定与旧数据兼容 ============

  test('无辣单 / 含辣单判定', () {
    final plain = mkOrder('001', [mkItem('原味鸡架', '鸡架', '原味', 1)]);
    final spicy = mkOrder('002', [
      mkItem('原味鸡架', '鸡架', '原味', 1),
      mkItem('辣味鸡架', '鸡架', '辣味', 1),
    ]);

    expect(plain.hasSpicy, isFalse);
    expect(plain.isPlainOnly, isTrue);

    expect(spicy.hasSpicy, isTrue);
    expect(spicy.isPlainOnly, isFalse);
  });

  test('旧订单没有标签快照时，退回按菜名分组且不报错', () {
    // 模拟几个月前存的老单：标签字段是空的
    final old = mkOrder('001', [
      mkItem('原味鸡架', '', '', 2),
      mkItem('辣味鸡架', '', '', 1),
    ]);

    final groups = aggregatePrep([old]);
    expect(groups.length, 2); // 两条各自成组，无法合并
    expect(groups.every((g) => !g.byCategory), isTrue);
  });

  test('订单序列化往返保留标签快照', () {
    final o = mkOrder('007', [mkItem('辣味鸡架', '鸡架', '辣味', 2)]);

    final back = decodeOrder(encodeOrder(o));
    expect(back, isNotNull);
    expect(back!.items.single.catTag, '鸡架');
    expect(back.items.single.flavorTag, '辣味');
    expect(back.items.single.isSpicy, isTrue);
    expect(back.isPlainOnly, isFalse);
  });

  test('旧版序列化数据（没有 c/f 键）也能解码', () {
    const oldJson =
        '{"id":"x","no":"001","items":[{"n":"原味鸡架","p":10.0,"q":2,"s":false}],'
        '"total":20.0,"note":"","time":"2026-01-01T12:00:00.000"}';

    final o = decodeOrder(oldJson);
    expect(o, isNotNull);
    expect(o!.items.single.catTag, '');
    expect(o.items.single.flavorTag, '');
    expect(o.items.single.quantity, 2);
  });
}
