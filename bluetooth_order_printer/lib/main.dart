import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:fast_gbk/fast_gbk.dart';

// ============================================================
// 精臣B3 蓝牙打印点单APP（外卖版）
// 经典蓝牙 SPP (UUID: 00001101-0000-1000-8000-00805F9B34FB)
// ESC/POS 指令 (MPT-II 便携热敏打印机, 50mm 纸)
//
// 架构说明:
//   - 蓝牙连接/扫描/发送全部通过 MethodChannel 交给 Android 原生处理
//   - GB2312 编码转换在 Android 原生侧 (java.nio.charset.Charset.forName("GBK"))
//   - Flutter 层只负责 UI 和业务逻辑
// ============================================================

// ==================== 平台通道 ====================

const platform = MethodChannel('com.example.bluetooth_order_printer/bluetooth');

// ==================== 数据模型 ====================

/// 标签定义（设置页维护）
///  - type='cat'    品类标签：把多个菜单项合并成同一款产品统计（如"鸡架"）
///  - type='flavor' 口味标签：在品类内部再细分（如"原味""辣味"）
/// isSpicy 只对口味标签有意义：吃这个口味要多一道工序，厨房后做
class TagDef {
  String name;
  String type; // 'cat' 品类 / 'flavor' 口味
  bool isSpicy;

  TagDef({required this.name, required this.type, this.isSpicy = false});

  bool get isCat => type == 'cat';
}

/// 菜单项（设置页维护）
class MenuItem {
  String name;
  double price;
  bool spicyEnabled; // 已废弃：旧的"支持辣度选择"开关，仅为兼容旧数据保留
  String catTag; // 品类标签名（如"鸡架"），空=未分类
  String flavorTag; // 口味标签名（如"原味""辣味"），空=无口味标记

  MenuItem({
    required this.name,
    required this.price,
    this.spicyEnabled = false,
    this.catTag = '',
    this.flavorTag = '',
  });
}

class OrderItem {
  String name;
  double price;
  int quantity;
  bool isSpicy; // 是否加辣（点单时按口味标签算好，快照保存）
  String catTag; // 品类标签快照（点单时从菜单项复制，之后改菜单不影响历史单）
  String flavorTag; // 口味标签快照

  OrderItem({
    required this.name,
    required this.price,
    required this.quantity,
    this.isSpicy = false,
    this.catTag = '',
    this.flavorTag = '',
  });

  /// 小计 = 单价 × 数量，保留两位小数
  double get subtotal => (price * quantity * 100).roundToDouble() / 100;
}

class Order {
  String id;
  String orderNo; // 3 位外卖单号，如 001
  List<OrderItem> items;
  double total;
  String note;
  DateTime time;

  /// 用餐方式：'dinein'=堂食（默认） 'takeaway'=打包 ''=未标记（旧版本订单）
  String diningType;

  /// 桌号（仅堂食有意义；空串 = 未指定桌号）
  String tableNo;

  Order({
    required this.id,
    required this.orderNo,
    required this.items,
    required this.total,
    required this.note,
    required this.time,
    this.diningType = 'dinein',
    this.tableNo = '',
  });

  bool get isDineIn => diningType == 'dinein';
  bool get isTakeaway => diningType == 'takeaway';

  /// 用餐方式打印文字：
  ///   堂食 + 桌号 → "堂食(Table:65)"；堂食未选桌号 → "堂食"
  ///   打包        → "打包"
  ///   旧订单未标记 → 空串（不打印这一行）
  String get diningLabel {
    if (isDineIn) {
      final t = tableNo.trim();
      return t.isEmpty ? '堂食' : '堂食(Table:$t)';
    }
    if (isTakeaway) return '打包';
    return '';
  }

  /// 备菜汇总单号前缀："(堂食)" / "(打包)" / 空串（旧订单未标记，沿用旧格式）
  String get diningPrefix {
    if (isDineIn) return '(堂食)';
    if (isTakeaway) return '(打包)';
    return '';
  }

  /// 整单里是否有加辣的菜品（有一份就算含辣）
  bool get hasSpicy => items.any((i) => i.isSpicy);

  /// 无辣单：整单没有任何加辣菜品 → 厨房不用多一道工序，可以先出
  bool get isPlainOnly => items.isNotEmpty && !hasSpicy;
}

// ==================== 本地存储（菜单 + 外卖单号）====================

class SettingsStore {
  static const _menuKey = 'menu_items';
  static const _seqKey = 'order_seq'; // 当前计数器（下一单号数字）
  static const _seqStartKey = 'order_seq_start'; // 起始数字

  // ---- 店铺名称（小票标题）----
  static const _storeNameKey = 'store_name';
  // 是否在小票上显示店铺名称（true=显示，false=隐藏）
  static const _showNameKey = 'show_store_name';

  static Future<String> getStoreName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_storeNameKey) ?? '美味小馆';
  }

  static Future<void> setStoreName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storeNameKey, name);
  }

  static Future<bool> getShowName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_showNameKey) ?? true;
  }

  static Future<void> setShowName(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showNameKey, v);
  }

  // 是否在小票上显示副标题（与店名独立，关闭店名仍可保留副标题）
  static const _showSubtitleKey = 'show_subtitle';

  static Future<bool> getShowSubtitle() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_showSubtitleKey) ?? true;
  }

  static Future<void> setShowSubtitle(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showSubtitleKey, v);
  }

  // ---- 小票样式（固定内容 + 字号 + 货币符号）----
  static const _paperWidthKey = 'paper_width';
  static const _footerKey = 'footer_text';
  static const _currencyKey = 'currency';
  static const _phoneKey = 'phone';
  static const _titleFontKey = 'title_font';
  static const _orderNoFontKey = 'orderno_font';
  static const _bodyFontKey = 'body_font';
  static const _subtitle1Key = 'subtitle1';
  static const _subtitle2Key = 'subtitle2';

  /// 纸张规格：'50mm' 或 '80mm'
  static Future<String> getPaperWidth() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_paperWidthKey) ?? '80mm';
  }

  static Future<void> setPaperWidth(String v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_paperWidthKey, v);
  }

  // ---- 平板模式与缩放 ----
  static const _tabletModeKey = 'tablet_mode';
  static const _uiScaleKey = 'ui_scale';

  /// 平板模式开关（true=启用平板布局，大按钮+网格菜单）
  static Future<bool> getTabletMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_tabletModeKey) ?? false;
  }

  static Future<void> setTabletMode(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_tabletModeKey, v);
  }

  /// 新建订单页面 UI 缩放比例（0.8 ~ 1.6，默认 1.0）
  static Future<double> getUiScale() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_uiScaleKey) ?? 1.0;
  }

  static Future<void> setUiScale(double v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_uiScaleKey, v);
  }

  // ---- 小票标签文字（可自定义）----
  static const _timeLabelKey = 'label_time';
  static const _dishLabelKey = 'label_dish';
  static const _qtyLabelKey = 'label_qty';
  static const _priceLabelKey = 'label_price';
  static const _subtotalLabelKey = 'label_subtotal';
  static const _totalLabelKey = 'label_total';

  static Future<String> _getLabel(String key, String def) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(key) ?? def;
  }

  static Future<void> _setLabel(String key, String v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, v);
  }

  static Future<String> getTimeLabel() => _getLabel(_timeLabelKey, '时间');
  static Future<void> setTimeLabel(String v) => _setLabel(_timeLabelKey, v);
  static Future<String> getDishLabel() => _getLabel(_dishLabelKey, '菜品');
  static Future<void> setDishLabel(String v) => _setLabel(_dishLabelKey, v);
  static Future<String> getQtyLabel() => _getLabel(_qtyLabelKey, '数量');
  static Future<void> setQtyLabel(String v) => _setLabel(_qtyLabelKey, v);
  static Future<String> getPriceLabel() => _getLabel(_priceLabelKey, '单价');
  static Future<void> setPriceLabel(String v) => _setLabel(_priceLabelKey, v);
  static Future<String> getSubtotalLabel() => _getLabel(_subtotalLabelKey, '小计');
  static Future<void> setSubtotalLabel(String v) => _setLabel(_subtotalLabelKey, v);
  static Future<String> getTotalLabel() => _getLabel(_totalLabelKey, '合计金额');
  static Future<void> setTotalLabel(String v) => _setLabel(_totalLabelKey, v);

  /// 店名下方副标题 1（留空不打印）
  static Future<String> getSubtitle1() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_subtitle1Key) ?? '';
  }

  static Future<void> setSubtitle1(String v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_subtitle1Key, v);
  }

  /// 店名下方副标题 2（留空不打印）
  static Future<String> getSubtitle2() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_subtitle2Key) ?? '';
  }

  static Future<void> setSubtitle2(String v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_subtitle2Key, v);
  }

  static Future<String> getFooterText() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_footerKey) ?? '谢谢惠顾，欢迎再次光临！';
  }

  static Future<void> setFooterText(String v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_footerKey, v);
  }

  static Future<String> getCurrency() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_currencyKey) ?? 'RM';
  }

  static Future<void> setCurrency(String v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_currencyKey, v);
  }

  static Future<String> getPhone() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_phoneKey) ?? '';
  }

  static Future<void> setPhone(String v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_phoneKey, v);
  }

  /// 字号索引：0=1x1, 1=1x2, 2=2x1, 3=2x2
  static Future<int> getTitleFont() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_titleFontKey) ?? 3; // 标题默认 2x2
  }

  static Future<void> setTitleFont(int v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_titleFontKey, v);
  }

  static Future<int> getOrderNoFont() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_orderNoFontKey) ?? 3; // 底部单号默认 2x2 大字
  }

  static Future<void> setOrderNoFont(int v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_orderNoFontKey, v);
  }

  static Future<int> getBodyFont() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_bodyFontKey) ?? 0; // 正文默认 1x1
  }

  static Future<void> setBodyFont(int v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_bodyFontKey, v);
  }

  // ---- 打印调试日志（排查打印失败用）----
  static const _logKey = 'print_logs';

  /// 记录一条调试日志（持久化，最多保留 200 条）
  static Future<void> addLog(String msg) async {
    final ts = DateTime.now().toString().substring(5, 19); // MM-dd HH:mm:ss
    final line = '[$ts] $msg';
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_logKey) ?? [];
      list.add(line);
      if (list.length > 200) list.removeRange(0, list.length - 200);
      await prefs.setStringList(_logKey, list);
    } catch (_) {}
  }

  /// 读取打印调试日志
  static Future<List<String>> loadLogs() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_logKey) ?? [];
  }

  /// 清空打印调试日志
  static Future<void> clearLogs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_logKey);
  }

  // ---- 菜单 ----
  static Future<List<MenuItem>> loadMenu() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_menuKey) ?? [];
    final menu = <MenuItem>[];
    for (final s in list) {
      try {
        final m = jsonDecode(s) as Map<String, dynamic>;
        menu.add(MenuItem(
          name: m['n'] as String,
          price: (m['p'] as num).toDouble(),
          spicyEnabled: m['s'] as bool? ?? false,
          catTag: (m['c'] as String?) ?? '',
          flavorTag: (m['f'] as String?) ?? '',
        ));
      } catch (_) {}
    }
    return menu;
  }

  static Future<void> saveMenu(List<MenuItem> menu) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _menuKey,
      menu.map((m) => jsonEncode({
        'n': m.name,
        'p': m.price,
        's': m.spicyEnabled,
        'c': m.catTag,
        'f': m.flavorTag,
      })).toList(),
    );
  }

  // ---- 标签库（品类 / 口味，设置页维护）----
  static const _tagKey = 'tag_defs';

  static Future<List<TagDef>> loadTags() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_tagKey) ?? [];
    final tags = <TagDef>[];
    for (final s in list) {
      try {
        final m = jsonDecode(s) as Map<String, dynamic>;
        final name = (m['n'] as String?) ?? '';
        if (name.trim().isEmpty) continue;
        tags.add(TagDef(
          name: name,
          type: (m['t'] as String?) ?? 'flavor',
          isSpicy: m['s'] as bool? ?? false,
        ));
      } catch (_) {}
    }
    return tags;
  }

  static Future<void> saveTags(List<TagDef> tags) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _tagKey,
      tags
          .map((t) => jsonEncode({'n': t.name, 't': t.type, 's': t.isSpicy}))
          .toList(),
    );
  }

  /// 按名称找标签；type 传 null 表示不限类型（取第一个同名标签）
  static TagDef? findTag(List<TagDef> tags, String name, {String? type}) {
    for (final t in tags) {
      if (t.name == name && (type == null || t.type == type)) return t;
    }
    return null;
  }

  /// 该口味标签是否属于"辣"（没定义或找不到都按不辣处理）
  static bool isSpicyFlavor(List<TagDef> tags, String flavorTag) {
    if (flavorTag.trim().isEmpty) return false;
    final t = findTag(tags, flavorTag, type: 'flavor');
    return t?.isSpicy ?? false;
  }

  /// 取所有品类标签名（去重，保持定义顺序）
  static List<String> catTagNames(List<TagDef> tags) =>
      tags.where((t) => t.isCat).map((t) => t.name).toList();

  /// 取所有口味标签名（去重，保持定义顺序）
  static List<String> flavorTagNames(List<TagDef> tags) =>
      tags.where((t) => !t.isCat).map((t) => t.name).toList();

  // ---- 外卖单号 ----
  static Future<int> getStartNo() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_seqStartKey) ?? 1;
  }

  /// 当前计数器（下一单将使用的数字）
  static Future<int> getCurrentNo() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_seqKey) ?? (prefs.getInt(_seqStartKey) ?? 1);
  }

  /// 设置起始数字并重置计数器（下次从该数字重新开始）
  static Future<void> setStartNo(int v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_seqStartKey, v);
    await prefs.setInt(_seqKey, v);
  }

  /// 付款二维码（base64 PNG）
  static const _qrKey = 'payment_qr_base64';

  static Future<String> getPaymentQr() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_qrKey) ?? '';
  }

  static Future<void> setPaymentQr(String base64) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_qrKey, base64);
  }

  // ---- 招牌图片 ----
  static const _logoKey = 'logo_base64';
  static const _logoPrintEnabledKey = 'logo_print_enabled';
  static const _logoPrintSizeKey = 'logo_print_size';

  static Future<String> getLogoBase64() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_logoKey) ?? '';
  }

  static Future<void> setLogoBase64(String base64) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_logoKey, base64);
  }

  static Future<bool> getLogoPrintEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_logoPrintEnabledKey) ?? true;
  }

  static Future<void> setLogoPrintEnabled(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_logoPrintEnabledKey, v);
  }

  /// 招牌打印大小：0=小 1=中 2=大
  static Future<int> getLogoPrintSize() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_logoPrintSizeKey) ?? 1;
  }

  static Future<void> setLogoPrintSize(int v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_logoPrintSizeKey, v);
  }

  // ---- 付款二维码打印大小（点阵像素）----
  static const _qrSizeKey = 'qr_print_size';

  /// 二维码打印大小（单位：像素点），有效范围 1~384（50mm纸满宽）
  static Future<int> getQrPrintSize() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_qrSizeKey) ?? 0; // 0=自动（默认中大小）
  }

  static Future<void> setQrPrintSize(int v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_qrSizeKey, v);
  }

  // ---- 桌号（堂食订单下拉选择，设置页维护）----
  static const _tableNosKey = 'table_nos';

  /// 桌号列表（按设置页添加顺序保存）
  static Future<List<String>> getTableNos() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_tableNosKey) ?? [];
  }

  static Future<void> setTableNos(List<String> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_tableNosKey, list);
  }

  /// 取下一单号并自增，如 1 → "001"，下一次取 2
  static Future<int> takeNextNo() async {
    final prefs = await SharedPreferences.getInstance();
    final cur = prefs.getInt(_seqKey) ?? (prefs.getInt(_seqStartKey) ?? 1);
    await prefs.setInt(_seqKey, cur + 1);
    return cur;
  }
}

/// 数字格式化为 3 位单号：1 → 001
String formatNo(int n) => n.toString().padLeft(3, '0');

/// 金额统一显示两位小数
String fmt(double v) => v.toStringAsFixed(2);

// ==================== 订单序列化（兼容旧数据）====================

String encodeOrder(Order o) => jsonEncode({
      'id': o.id,
      'no': o.orderNo,
      'items': o.items.map((i) => {
        'n': i.name,
        'p': i.price,
        'q': i.quantity,
        's': i.isSpicy,
        'c': i.catTag,
        'f': i.flavorTag,
      }).toList(),
      'total': o.total,
      'note': o.note,
      'time': o.time.toIso8601String(),
      'dt': o.diningType, // 用餐方式：dinein / takeaway
      'tn': o.tableNo, // 堂食桌号
    });

Order? decodeOrder(String json) {
  try {
    final map = jsonDecode(json) as Map<String, dynamic>;
    final itemsRaw = map['items'] as List? ?? [];
    final items = itemsRaw.map((e) {
      final m = e as Map<String, dynamic>;
      return OrderItem(
        name: m['n'] as String,
        price: (m['p'] as num).toDouble(),
        quantity: (m['q'] as num).toInt(),
        isSpicy: m['s'] as bool? ?? false,
        // 旧订单没有标签快照 → 空串，打印时回退到按菜名分组
        catTag: (m['c'] as String?) ?? '',
        flavorTag: (m['f'] as String?) ?? '',
      );
    }).toList();
    return Order(
      id: map['id'] as String,
      // 兼容旧版本：旧单存的是桌号字段 "t"，新版本用 "no"
      orderNo: (map['no'] as String?) ?? (map['t'] as String? ?? ''),
      items: items,
      total: (map['total'] as num).toDouble(),
      note: map['note'] as String? ?? '',
      time: DateTime.parse(map['time'] as String),
      // 旧版本订单没有用餐方式字段 → 空串表示"未标记"，打印时沿用旧格式
      diningType: (map['dt'] as String?) ?? '',
      tableNo: (map['tn'] as String?) ?? '',
    );
  } catch (_) {
    return null;
  }
}

// ==================== ESC/POS 小票生成（MPT-II 便携热敏打印机）====================
//
// MPT-II 使用 ESC/POS 指令集（热敏小票打印机标准），不是 TSPL（标签机指令）。
// 之前用 TSPL 发给 MPT-II 无法解析，导致"连接成功但打印无输出"。
// 控制字节（ESC=0x1B、LF=0x0A 等）直接以转义字符写入字符串；
// GBK 编码兼容 ASCII，原生侧 Charset.forName("GBK") 编码后原样保留。
// 行宽按 32 半角字符设计（50mm 纸，正常字号 12x24 点阵）。

/// 半角显示宽度：全角字符按 2 算
int _dispWidth(String s) {
  var w = 0;
  for (final c in s.codeUnits) {
    w += c > 0xFF ? 2 : 1;
  }
  return w;
}

/// 补齐到指定半角宽度；right=true 右对齐（左侧补空格）
String _padTo(String s, int w, {bool right = false}) {
  final pad = w - _dispWidth(s);
  if (pad <= 0) return s;
  return right ? (' ' * pad) + s : s + (' ' * pad);
}

/// 补齐到指定半角宽度并居中
String _padCenter(String s, int w) {
  final pad = w - _dispWidth(s);
  if (pad <= 0) return s;
  final left = pad ~/ 2;
  return (' ' * left) + s + (' ' * (pad - left));
}

/// 按半角宽度截断，保留 2 字符宽度放".."
String _truncateW(String s, int w) {
  var cur = 0;
  final buf = StringBuffer();
  for (final c in s.runes) {
    final cw = c > 0xFF ? 2 : 1;
    if (cur + cw > w - 2) break;
    buf.writeCharCode(c);
    cur += cw;
  }
  return '${buf}..';
}

/// 按半角宽度自动换行，返回多行列表（每行显示宽度 <= maxW）
List<String> _wrapLines(String s, int maxW) {
  if (s.isEmpty) return [s];
  final lines = <String>[];
  var cur = StringBuffer();
  var curW = 0;
  for (final c in s.runes) {
    final cw = c > 0xFF ? 2 : 1;
    if (curW + cw > maxW) {
      lines.add(cur.toString());
      cur = StringBuffer();
      curW = 0;
    }
    cur.writeCharCode(c);
    curW += cw;
  }
  if (cur.isNotEmpty) lines.add(cur.toString());
  return lines.isEmpty ? [s] : lines;
}

/// 小票样式配置（全部可在设置页修改）
class ReceiptSettings {
  final String paperWidth; // 纸张规格 '50mm' 或 '80mm'
  final String storeName; // 店铺名（标题）
  final String subtitle1; // 店名下方副标题 1（留空不打印）
  final String subtitle2; // 店名下方副标题 2（留空不打印）
  final String footerText; // 底部提示语
  final String currency; // 货币符号（默认 RM）
  final String phone; // 手机号（空则不打印）
  final int titleFont; // 标题字号 0=1x1 1=1x2 2=2x1 3=2x2
  final int orderNoFont; // 底部单号字号
  final int bodyFont; // 正文字号（仅 0=1x1 或 1=1x2，宽不变不折行）
  final String timeLabel; // "时间" 标签
  final String dishLabel; // "菜品" 标签
  final String qtyLabel; // "数量" 标签
  final String priceLabel; // "单价" 标签
  final String subtotalLabel; // "小计" 标签
  final String totalLabel; // "合计金额" 标签
  final String qrBase64;        // 付款二维码 base64 PNG（空则不打印）
  final String logoBase64;       // 招牌图片 base64 PNG（空则不打印）
  final bool logoPrintEnabled;   // 是否打印招牌图片
  final int logoPrintSize;       // 打印大小：0=小 1=中 2=大
  final bool showName;           // 是否显示店铺名称（true=显示，false=隐藏）
  final bool showSubtitle;       // 是否显示副标题（与店名独立）
  final int qrPrintSize;         // 付款二维码打印大小：0=自动 非0=像素点数
  const ReceiptSettings({
    required this.paperWidth,
    required this.storeName,
    required this.subtitle1,
    required this.subtitle2,
    required this.footerText,
    required this.currency,
    required this.phone,
    required this.titleFont,
    required this.orderNoFont,
    required this.bodyFont,
    required this.timeLabel,
    required this.dishLabel,
    required this.qtyLabel,
    required this.priceLabel,
    required this.subtotalLabel,
    required this.totalLabel,
    this.qrBase64 = '',
    this.logoBase64 = '',
    this.logoPrintEnabled = true,
    this.logoPrintSize = 1,
    this.showName = true,
    this.showSubtitle = true,
    this.qrPrintSize = 0,
  });
}

/// GS ! 字号字节：索引 0=1x1(0x00) 1=1x2(0x01) 2=2x1(0x10) 3=2x2(0x11)
const _gsFonts = [0x00, 0x01, 0x10, 0x11];

/// 从设置加载小票样式
Future<ReceiptSettings> loadReceiptSettings() async {
  return ReceiptSettings(
    paperWidth: await SettingsStore.getPaperWidth(),
    storeName: await SettingsStore.getStoreName(),
    subtitle1: await SettingsStore.getSubtitle1(),
    subtitle2: await SettingsStore.getSubtitle2(),
    footerText: await SettingsStore.getFooterText(),
    currency: await SettingsStore.getCurrency(),
    phone: await SettingsStore.getPhone(),
    titleFont: await SettingsStore.getTitleFont(),
    orderNoFont: await SettingsStore.getOrderNoFont(),
    bodyFont: await SettingsStore.getBodyFont(),
    timeLabel: await SettingsStore.getTimeLabel(),
    dishLabel: await SettingsStore.getDishLabel(),
    qtyLabel: await SettingsStore.getQtyLabel(),
    priceLabel: await SettingsStore.getPriceLabel(),
    subtotalLabel: await SettingsStore.getSubtotalLabel(),
    totalLabel: await SettingsStore.getTotalLabel(),
    qrBase64: await SettingsStore.getPaymentQr(),
    logoBase64: await SettingsStore.getLogoBase64(),
    logoPrintEnabled: await SettingsStore.getLogoPrintEnabled(),
    logoPrintSize: await SettingsStore.getLogoPrintSize(),
    showName: await SettingsStore.getShowName(),
    showSubtitle: await SettingsStore.getShowSubtitle(),
    qrPrintSize: await SettingsStore.getQrPrintSize(),
  );
}

int _getLogoPx(String paperWidth, int sizeIndex) {
  final is80mm = paperWidth == '80mm';
  if (sizeIndex == 0) return is80mm ? 160 : 120;
  if (sizeIndex == 2) return is80mm ? 420 : 300;
  return is80mm ? 280 : 200; // 默认中 (1)
}

String buildEscPos(Order o, ReceiptSettings s) {
  final sb = StringBuffer();
  sb.write('\x1B\x40'); // ESC @ 初始化打印机（复位所有设置）

  final is80mm = s.paperWidth == '80mm';
  final lineWidth = is80mm ? 48 : 32;

  // ===== 店铺标题：居中 + 可调字号（设置页可改）=====
  if (s.showName) {
    final title = cleanText(s.storeName.trim().isEmpty ? '美味小馆' : s.storeName.trim());
    final titleMax = switch (s.titleFont) {
      0 => is80mm ? 44 : 30,
      3 => is80mm ? 12 : 8,
      _ => is80mm ? 24 : 16,
    };
    final td = _dispWidth(title) > titleMax ? _truncateW(title, titleMax) : title;
    sb.write('\x1B\x61\x01'); // 居中
    sb.write('\x1D\x21');
    sb.writeCharCode(_gsFonts[s.titleFont]);
    sb.writeln('*$td*');
    sb.write('\x1D\x21\x00');
    sb.write('\x1B\x61\x00'); // 左对齐
  }
  // ===== 副标题两行（设置页可配，留空不打印；独立于店名开关）=====
  if (s.showSubtitle) {
    final sub1 = cleanText(s.subtitle1.trim());
    final sub2 = cleanText(s.subtitle2.trim());
    if (sub1.isNotEmpty || sub2.isNotEmpty) {
      sb.write('\x1B\x61\x01'); // 居中
      if (sub1.isNotEmpty) {
        for (final line in _wrapLines(sub1, lineWidth)) {
          sb.writeln(line);
        }
      }
      if (sub2.isNotEmpty) {
        for (final line in _wrapLines(sub2, lineWidth)) {
          sb.writeln(line);
        }
      }
      sb.write('\x1B\x61\x00'); // 左对齐
    }
  }

  // ===== 分隔线 + 时间（单号已移到底部；标签文字可配置）=====
  sb.writeln('-' * lineWidth);
  sb.writeln('${s.timeLabel.trim().isEmpty ? '时间' : s.timeLabel.trim()}：${formatTime(o.time)}');
  sb.writeln('-' * lineWidth);

  // ===== 正文（表头/菜品/合计/备注）字号 =====
  final useBodyFont = s.bodyFont != 0;
  if (useBodyFont) {
    sb.write('\x1D\x21');
    sb.writeCharCode(_gsFonts[s.bodyFont]);
  }

  // ===== 商品表头（四列：名称左/数量居中/单价右/小计右）=====
  final nameW = is80mm ? 22 : 12;
  final qtyW = is80mm ? 6 : 5;
  final priceW = is80mm ? 9 : 7;
  final subtotalW = is80mm ? 11 : 8;

  final dishLabel = s.dishLabel.trim().isEmpty ? '菜品' : s.dishLabel.trim();
  final qtyLabel = s.qtyLabel.trim().isEmpty ? '数量' : s.qtyLabel.trim();
  final priceLabel = s.priceLabel.trim().isEmpty ? '单价' : s.priceLabel.trim();
  final subtotalLabel = s.subtotalLabel.trim().isEmpty ? '小计' : s.subtotalLabel.trim();
  sb.writeln(_padTo(dishLabel, nameW) +
      _padCenter(qtyLabel, qtyW) +
      _padTo(priceLabel, priceW, right: true) +
      _padTo(subtotalLabel, subtotalW, right: true));
  sb.writeln('-' * lineWidth);

  // ===== 商品行（含数量+单价的小计金额；单价不带货币符号）=====
  for (final it in o.items) {
    final rawName = cleanText(it.name);
    final displayName = rawName;
    final nameLines = _wrapLines(displayName, nameW);
    sb.writeln(_padTo(nameLines[0], nameW) +
        _padCenter('${it.quantity}', qtyW) +
        _padTo(fmt(it.price), priceW, right: true) +
        _padTo('${s.currency}${fmt(it.subtotal)}', subtotalW, right: true));
    for (var i = 1; i < nameLines.length; i++) {
      sb.writeln(_padTo(nameLines[i], nameW) + ' ' * (qtyW + priceW + subtotalW));
    }
  }
  sb.writeln('-' * lineWidth);

  // ===== 合计金额（标签与货币符号均可配置，默认 RM）=====
  final totalLabel = s.totalLabel.trim().isEmpty ? '合计金额' : s.totalLabel.trim();
  sb.writeln(_padTo('$totalLabel：${s.currency}${fmt(o.total)}', lineWidth, right: true));

  if (o.note.isNotEmpty) {
    sb.writeln('备注：${cleanText(o.note)}');
  }
  if (useBodyFont) sb.write('\x1D\x21\x00'); // 恢复正文前字号
  sb.writeln(''); // 空行

  // ===== 底部：手机号（可选）+ 提示语（可配置，居中）=====
  sb.write('\x1B\x61\x01'); // 居中
  final phone = cleanText(s.phone.trim());
  if (phone.isNotEmpty) {
    sb.writeln('手机号：$phone');
  }
  sb.writeln(cleanText(
      s.footerText.trim().isEmpty ? '谢谢惠顾，欢迎再次光临！' : s.footerText.trim()));
  sb.write('\x1B\x61\x00'); // 左对齐
  // ===== 单号放最下面：居中 + 可调字号（默认 2x2 大字，方便核对）=====
  sb.write('\x1B\x61\x01'); // 居中
  sb.write('\x1D\x21');
  sb.writeCharCode(_gsFonts[s.orderNoFont]);
  sb.writeln('单号：${o.orderNo}');
  sb.write('\x1D\x21\x00');
  sb.write('\x1B\x61\x00');

  // ===== 付款二维码（若已上传则打印，位于单号下方，含"QR Payment"标签）=====
  if (s.qrBase64.isNotEmpty) {
    sb.writeln(''); // 空行间隔
    // 居中标签 "QR Payment"
    sb.write('\x1B\x61\x01');
    sb.writeln('QR Payment');
    sb.write('\x1B\x61\x00');
  }

  return sb.toString();
}

/// 将 base64 PNG 转换为兼容性极高的 ESC * 33 24 点阵双密度位图数据流
/// 专为精臣 B3 / MPT-II / 芯烨等热敏小票机优化：
///  - 使用 100% 全兼容的 ESC * 33 (0x1B 0x2A 33 nL nH) 经典双密度 24 点阵指令
///  - 配合 ESC 3 0 (\x1B\x33\x00) 消除 Stripe 间白缝，图像纵向平滑连接
///  - 内置左右边距填充，使二维码 100% 居中，行宽与 50mm(384点) / 80mm(576点) 打印头完全一致
Uint8List? _pngToEscPosRasterBytes(String base64Str, {required String paperWidth, int? targetPx, int qrPrintSize = 0}) {
  try {
    final parts = base64Str.split(',');
    final data = parts.length > 1 ? parts[1] : base64Str;
    final bytes = base64Decode(data);
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;

    final is80mm = paperWidth == '80mm';
    // 80mm 点阵总宽 576 点，50mm 点阵总宽 384 点
    final canvasWidth = is80mm ? 576 : 384;
    // qrPrintSize: 0=自动，非0=用户指定像素数
    final autoSizes = <int>[is80mm ? 192 : 160, is80mm ? 288 : 240, is80mm ? 432 : 320];
    final defaultPx = qrPrintSize != 0 ? qrPrintSize : autoSizes[1];
    final qrSize = (targetPx ?? defaultPx).clamp(1, canvasWidth);

    final leftPaddingDots = (canvasWidth - qrSize) ~/ 2;

    // 转灰度并按居中尺寸缩放
    final gray = img.grayscale(decoded);
    final scaled = img.copyResize(gray, width: qrSize, height: qrSize, interpolation: img.Interpolation.nearest);

    final height = scaled.height;
    final buffer = <int>[];

    // 1. 设置位图显示行间距（ESC 3 0），确保图像纵向无缝接
    buffer.addAll([0x1B, 0x33, 0]);

    // 2. 纵向每 24 像素切为一个 Stripe 扫描到
    for (var r = 0; r < height; r += 24) {
      // ESC * 33 nL nH (33 表示 24-dot double density 模式)
      buffer.addAll([0x1B, 0x2A, 33, canvasWidth & 0xFF, (canvasWidth >> 8) & 0xFF]);

      for (var col = 0; col < canvasWidth; col++) {
        if (col < leftPaddingDots || col >= leftPaddingDots + qrSize) {
          // 左右边距空白列：3 字节 0x00
          buffer.addAll([0x00, 0x00, 0x00]);
        } else {
          final x = col - leftPaddingDots;
          int b0 = 0, b1 = 0, b2 = 0;

          for (var bit = 0; bit < 8; bit++) {
            final y0 = r + bit;
            if (y0 < height) {
              final p = scaled.getPixel(x, y0);
              if (((p.r + p.g + p.b) / 3).round() < 128) {
                b0 |= (1 << (7 - bit));
              }
            }

            final y1 = r + 8 + bit;
            if (y1 < height) {
              final p = scaled.getPixel(x, y1);
              if (((p.r + p.g + p.b) / 3).round() < 128) {
                b1 |= (1 << (7 - bit));
              }
            }

            final y2 = r + 16 + bit;
            if (y2 < height) {
              final p = scaled.getPixel(x, y2);
              if (((p.r + p.g + p.b) / 3).round() < 128) {
                b2 |= (1 << (7 - bit));
              }
            }
          }
          buffer.addAll([b0, b1, b2]);
        }
      }
      // 换行：使用 ESC J 0 (打印并进纸 0 点)，避免 0x0A 带来的额外进纸
      buffer.addAll([0x1B, 0x4A, 0]);
    }

    // 3. 恢复默认行间距（ESC 2）
    buffer.addAll([0x1B, 0x32]);

    return Uint8List.fromList(buffer);
  } catch (e) {
    return null;
  }
}

/// 构建小票并生成 Byte 块列表（支持文本、🌶 辣椒位图图标与 Raw Byte 位图混合）
List<Uint8List> buildEscPosBytesChunks(Order o, ReceiptSettings s) {
  final chunks = <Uint8List>[];
  final is80mm = s.paperWidth == '80mm';
  final lineWidth = is80mm ? 48 : 32;

  // ===== 0. 用餐方式（堂食(Table:x) / 打包）：打在招牌图片上方，最先出现 =====
  final diningLabel = o.diningLabel;
  if (diningLabel.isNotEmpty) {
    final sbDining = StringBuffer();
    sbDining.write('\x1B\x40'); // ESC @ 初始化
    sbDining.write('\x1B\x61\x01'); // 居中
    sbDining.write('\x1D\x21');
    sbDining.writeCharCode(_gsFonts[1]); // 1x2 放大
    sbDining.writeln(cleanText(diningLabel));
    sbDining.write('\x1D\x21\x00');
    sbDining.write('\x1B\x61\x00'); // 左对齐
    chunks.add(Uint8List.fromList(gbk.encode(sbDining.toString())));
  }

  // ===== 1. Logo =====
  if (s.logoPrintEnabled && s.logoBase64.isNotEmpty) {
    final logoPx = _getLogoPx(s.paperWidth, s.logoPrintSize);
    final logoBytes = _pngToEscPosRasterBytes(s.logoBase64, paperWidth: s.paperWidth, targetPx: logoPx);
    if (logoBytes != null && logoBytes.isNotEmpty) {
      chunks.add(Uint8List.fromList([0x1B, 0x40])); // 初始化
      chunks.add(logoBytes);
      chunks.add(Uint8List.fromList(gbk.encode('\n')));
    }
  }

  // ===== 1. 头部内容 =====
  final sbHead = StringBuffer();
  sbHead.write('\x1B\x40'); // ESC @ 初始化打印机

  // 店铺标题（showName=false 时跳过）
  if (s.showName) {
    final title = cleanText(s.storeName.trim().isEmpty ? '美味小馆' : s.storeName.trim());
    final titleMax = switch (s.titleFont) {
      0 => is80mm ? 44 : 30,
      3 => is80mm ? 12 : 8,
      _ => is80mm ? 24 : 16,
    };
    final td = _dispWidth(title) > titleMax ? _truncateW(title, titleMax) : title;
    sbHead.write('\x1B\x61\x01'); // 居中
    sbHead.write('\x1D\x21');
    sbHead.writeCharCode(_gsFonts[s.titleFont]);
    sbHead.writeln('*$td*');
    sbHead.write('\x1D\x21\x00');
    sbHead.write('\x1B\x61\x00'); // 左对齐
  }

  // 副标题（showSubtitle=false 时跳过，与店名独立控制）
  if (s.showSubtitle) {
    final sub1 = cleanText(s.subtitle1.trim());
    final sub2 = cleanText(s.subtitle2.trim());
    if (sub1.isNotEmpty || sub2.isNotEmpty) {
      sbHead.write('\x1B\x61\x01');
      if (sub1.isNotEmpty) {
        for (final line in _wrapLines(sub1, lineWidth)) {
          sbHead.writeln(line);
        }
      }
      if (sub2.isNotEmpty) {
        for (final line in _wrapLines(sub2, lineWidth)) {
          sbHead.writeln(line);
        }
      }
      sbHead.write('\x1B\x61\x00');
    }
  }

  // 分隔线 + 时间（日/月/年 带年份，如 29/08/2026 14:30）
  sbHead.writeln('-' * lineWidth);
  final t = o.time;
  final dateStr = '${t.day.toString().padLeft(2, '0')}/${t.month.toString().padLeft(2, '0')}/${t.year}';
  final timeStr = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  sbHead.writeln('${s.timeLabel.trim().isEmpty ? '时间' : s.timeLabel.trim()}：$dateStr $timeStr');
  sbHead.writeln('-' * lineWidth);

  // 正文字号
  final useBodyFont = s.bodyFont != 0;
  if (useBodyFont) {
    sbHead.write('\x1D\x21');
    sbHead.writeCharCode(_gsFonts[s.bodyFont]);
  }

  // 表头
  final nameW = is80mm ? 22 : 12;
  final qtyW = is80mm ? 6 : 5;
  final priceW = is80mm ? 9 : 7;
  final subtotalW = is80mm ? 11 : 8;

  final dishLabel = s.dishLabel.trim().isEmpty ? '菜品' : s.dishLabel.trim();
  final qtyLabel = s.qtyLabel.trim().isEmpty ? '数量' : s.qtyLabel.trim();
  final priceLabel = s.priceLabel.trim().isEmpty ? '单价' : s.priceLabel.trim();
  final subtotalLabel = s.subtotalLabel.trim().isEmpty ? '小计' : s.subtotalLabel.trim();
  sbHead.writeln(_padTo(dishLabel, nameW) +
      _padCenter(qtyLabel, qtyW) +
      _padTo(priceLabel, priceW, right: true) +
      _padTo(subtotalLabel, subtotalW, right: true));
  sbHead.writeln('-' * lineWidth);

  // 写入头部
  for (final l in _splitByLine(sbHead.toString())) {
    chunks.add(Uint8List.fromList(gbk.encode(l)));
  }

  // ===== 2. 商品行列表（自动换行；发票不标辣，辣/不辣由厨房单与备菜汇总体现）=====
  for (final it in o.items) {
    final cleanName = cleanText(it.name);
    final nameLines = _wrapLines(cleanName, nameW);
    // 第一行带上数量、单价、小计
    final lineStr = _padTo(nameLines[0], nameW) +
        _padCenter('${it.quantity}', qtyW) +
        _padTo(fmt(it.price), priceW, right: true) +
        _padTo('${s.currency}${fmt(it.subtotal)}', subtotalW, right: true) +
        '\n';
    chunks.add(Uint8List.fromList(gbk.encode(lineStr)));

    // 剩余行只打印名字，数量/单价/小计列留空
    for (var i = 1; i < nameLines.length; i++) {
      final extraLine = _padTo(nameLines[i], nameW) +
          ' ' * (qtyW + priceW + subtotalW) + '\n';
      chunks.add(Uint8List.fromList(gbk.encode(extraLine)));
    }
  }

  // ===== 3. 尾部内容 =====
  final sbFoot = StringBuffer();
  sbFoot.writeln('-' * lineWidth);
  final totalLabel = s.totalLabel.trim().isEmpty ? '合计金额' : s.totalLabel.trim();
  // TOTAL 金额：放大 2 号（2x2 大字）并加粗（ESC E），标签同样加粗
  // 行内切字号：填充空格按默认列宽计算，金额按 2 倍宽预留，保证右对齐且不折行
  final totalLabelStr = '$totalLabel：';
  final totalAmountStr = '${s.currency} ${fmt(o.total)}'; // 钱符与金额空一格
  final totalPad = (lineWidth - _dispWidth(totalLabelStr) - _dispWidth(totalAmountStr) * 2)
      .clamp(0, lineWidth);
  sbFoot.write(' ' * totalPad);
  sbFoot.write('\x1B\x45\x01'); // ESC E 1 加粗开（标签与金额均加粗）
  sbFoot.write(totalLabelStr);
  sbFoot.write('\x1D\x21');
  sbFoot.writeCharCode(_gsFonts[3]); // 2x2 大字
  sbFoot.write(totalAmountStr);
  sbFoot.write('\x1D\x21');
  sbFoot.writeCharCode(useBodyFont ? _gsFonts[s.bodyFont] : 0x00); // 恢复正文字号
  sbFoot.write('\x1B\x45\x00'); // 加粗关
  sbFoot.writeln();

  if (o.note.isNotEmpty) {
    sbFoot.writeln('备注：${cleanText(o.note)}');
  }
  if (useBodyFont) sbFoot.write('\x1D\x21\x00'); // 恢复字号
  sbFoot.writeln('');

  // 手机号与底部提示
  sbFoot.write('\x1B\x61\x01'); // 居中
  final phone = cleanText(s.phone.trim());
  if (phone.isNotEmpty) {
    sbFoot.writeln('手机号：$phone');
  }
  sbFoot.writeln(cleanText(
      s.footerText.trim().isEmpty ? '谢谢惠顾，欢迎再次光临！' : s.footerText.trim()));
  sbFoot.write('\x1B\x61\x00'); // 左对齐

  // 单号大字
  sbFoot.write('\x1B\x61\x01');
  sbFoot.write('\x1D\x21');
  sbFoot.writeCharCode(_gsFonts[s.orderNoFont]);
  sbFoot.writeln('单号：${o.orderNo}');
  sbFoot.write('\x1D\x21\x00');
  sbFoot.write('\x1B\x61\x00');

  if (s.qrBase64.isNotEmpty) {
    sbFoot.writeln('');
    sbFoot.write('\x1B\x61\x01');
    sbFoot.writeln('QR Payment');
    sbFoot.write('\x1B\x61\x00');
  }

  for (final l in _splitByLine(sbFoot.toString())) {
    chunks.add(Uint8List.fromList(gbk.encode(l)));
  }

  // ===== 4. 付款二维码位图数据 =====
  if (s.qrBase64.isNotEmpty) {
    final qrBytes = _pngToEscPosRasterBytes(s.qrBase64, paperWidth: s.paperWidth, qrPrintSize: s.qrPrintSize);
    if (qrBytes != null && qrBytes.isNotEmpty) {
      chunks.add(qrBytes);
    }
  }

  // ===== 5. 走纸 5 行 =====
  chunks.add(Uint8List.fromList(gbk.encode('\x1B\x64\x05')));

  return chunks;
}

/// 构建厨房联小票并生成 Byte 块列表（简洁烧烤风格，包含 emoji 🦴🍗🐔）
List<Uint8List> buildKitchenEscPosBytesChunks(Order o, ReceiptSettings s) {
  final chunks = <Uint8List>[];
  final is80mm = s.paperWidth == '80mm';
  final lineWidth = is80mm ? 48 : 32;

  // ===== 0. Logo（厨房单不打印招牌图片，仅发票打印）=====

  // ===== 1. 头部内容 =====
  final sbHead = StringBuffer();
  sbHead.write('\x1B\x40'); // ESC @ 初始化打印机

  // 用餐方式（堂食(Table:x) / 打包）：打在最顶部，厨房一眼看到送餐方式
  final diningLabel = o.diningLabel;
  if (diningLabel.isNotEmpty) {
    sbHead.write('\x1B\x61\x01'); // 居中
    sbHead.write('\x1D\x21');
    sbHead.writeCharCode(_gsFonts[1]); // 1x2 放大
    sbHead.writeln(cleanText(diningLabel));
    sbHead.write('\x1D\x21\x00');
    sbHead.write('\x1B\x61\x00'); // 左对齐
  }

  // 店铺标题（showName=false 时跳过）
  if (s.showName) {
    final title = cleanText(s.storeName.trim().isEmpty ? '美味小馆' : s.storeName.trim());
    sbHead.write('\x1B\x61\x01'); // 居中
    sbHead.write('\x1D\x21');
    sbHead.writeCharCode(_gsFonts[s.titleFont]);
    sbHead.writeln(title);
    sbHead.write('\x1D\x21\x00');
    sbHead.write('\x1B\x61\x00'); // 左对齐
  }

  // 厨房单不打印副标题 1、2（仅发票打印，与店名无关）

  // ORDER 这一行
  final dateStr = '${o.time.year}${o.time.month.toString().padLeft(2, '0')}${o.time.day.toString().padLeft(2, '0')}';
  final orderNumPadded = o.orderNo.padLeft(4, '0');
  final timeStr = '${o.time.hour.toString().padLeft(2, '0')}:${o.time.minute.toString().padLeft(2, '0')}';
  
  sbHead.writeln('=' * lineWidth);
  sbHead.writeln('ORDER:$dateStr$orderNumPadded  $timeStr');
  sbHead.writeln('=' * lineWidth);

  // 外卖单号大字（居中，与发票尾部的单号风格一致，厨房一眼可见）
  sbHead.write('\x1B\x61\x01'); // 居中
  sbHead.write('\x1D\x21');
  sbHead.writeCharCode(_gsFonts[s.orderNoFont]);
  sbHead.writeln('外卖单号:$orderNumPadded');
  sbHead.write('\x1D\x21\x00');
  sbHead.write('\x1B\x61\x00'); // 左对齐

  // 无辣 / 含辣 大字标记：厨房按这个决定先后（辣味的要多一道工序）
  sbHead.write('\x1B\x61\x01'); // 居中
  sbHead.write('\x1D\x21');
  sbHead.writeCharCode(_gsFonts[1]); // 1x2 高
  sbHead.writeln(o.isPlainOnly ? '** 无辣 **' : '** 含辣 **');
  sbHead.write('\x1D\x21\x00');
  sbHead.write('\x1B\x61\x00'); // 左对齐

  // 写入头部
  for (final l in _splitByLine(sbHead.toString())) {
    chunks.add(Uint8List.fromList(gbk.encode(l)));
  }

  // ===== 2. 商品行列表（不进行 emoji 清理以保留 🦴🍗🐔，并自动换行）=====
  // 厨房单产品字体固定放大为 1x2（GS ! 0x01：宽 1 倍、高 2 倍），方便厨房看清菜品；
  // 宽度不变故折行宽度无需调整，与发票正文（1x1）相互独立
  final bodyFontInit = '\x1D\x21\x01';
  final bodyFontReset = '\x1D\x21\x00';

  for (final it in o.items) {
    // 保留原始名称中的 emoji；数量始终显示（包含数量为 1 时）
    final displayName = it.name;
    final qtySuffix = ' x${it.quantity}';
    final fullLineText = '$displayName$qtySuffix';
    
    final nameLines = _wrapLines(fullLineText, lineWidth);
    final itemSb = StringBuffer();
    itemSb.write(bodyFontInit);
    for (final line in nameLines) {
      itemSb.writeln(line);
    }
    itemSb.write(bodyFontReset);
    
    chunks.add(Uint8List.fromList(gbk.encode(itemSb.toString())));
  }

  // ===== 3. 尾部内容 =====
  final sbFoot = StringBuffer();
  sbFoot.writeln('-' * lineWidth);
  // TOTAL 金额：放大 2 号（2x2 大字）并加粗（ESC E），与发票一致
  sbFoot.write('TOTAL: ');
  sbFoot.write('\x1B\x45\x01'); // ESC E 1 加粗开
  sbFoot.write('\x1D\x21');
  sbFoot.writeCharCode(_gsFonts[3]); // 2x2 大字
  sbFoot.write('${s.currency} ${fmt(o.total)}');
  sbFoot.write('\x1D\x21\x00'); // 恢复默认字号
  sbFoot.write('\x1B\x45\x00'); // 加粗关
  sbFoot.writeln();
  if (o.note.isNotEmpty) {
    sbFoot.writeln('备注:${o.note}'); // 冒号后无空格
  }

  // 走纸 5 行
  sbFoot.write('\x1B\x64\x05');

  for (final l in _splitByLine(sbFoot.toString())) {
    chunks.add(Uint8List.fromList(gbk.encode(l)));
  }

  return chunks;
}

// ==================== 备菜汇总聚合（打印与界面共用同一份逻辑）====================

/// 一个品类分组的备菜统计：同一品类标签的菜合并到一起，按"辣 / 不辣"二分
class PrepGroup {
  final String name; // 显示名：有品类标签用标签名，没有则用菜品名
  final bool byCategory; // true=挂了品类标签（展开"共/不辣/辣"），false=按菜名单行显示
  final int plainQty; // 不辣份数（没标口味的算不辣）
  final int spicyQty; // 辣份数
  const PrepGroup({
    required this.name,
    required this.byCategory,
    required this.plainQty,
    required this.spicyQty,
  });

  int get total => plainQty + spicyQty;
}

/// 把若干订单按品类合并统计：
///  - 挂了品类标签的菜（原味鸡架 + 辣味鸡架）合并成一个分组
///  - 没挂品类标签的菜自己单独成组，沿用原来的按菜名统计
/// 排序：按总份数降序（同数量按名称）
List<PrepGroup> aggregatePrep(List<Order> orders) {
  // 分组键 -> [不辣份数, 辣份数]；没标签的菜名加 ## 前缀，避免和同名品类标签撞车
  final map = <String, List<int>>{};
  final nameOf = <String, String>{};
  for (final o in orders) {
    for (final it in o.items) {
      final cat = it.catTag.trim();
      final key = cat.isEmpty ? '##${it.name}' : cat;
      nameOf[key] = cat.isEmpty ? it.name : cat;
      final e = map.putIfAbsent(key, () => [0, 0]);
      if (it.isSpicy) {
        e[1] += it.quantity;
      } else {
        e[0] += it.quantity;
      }
    }
  }

  return map.entries
      .map((e) => PrepGroup(
            name: nameOf[e.key] ?? e.key,
            byCategory: !e.key.startsWith('##'),
            plainQty: e.value[0],
            spicyQty: e.value[1],
          ))
      .toList()
    ..sort((a, b) {
      final byQty = b.total.compareTo(a.total);
      if (byQty != 0) return byQty;
      return a.name.compareTo(b.name);
    });
}

/// 汇总部分的分行文本（打印用）：
///  挂了品类标签 → "[鸡翅] 共 10" + "  不辣 x 5" + "  辣 x 5"（辣为 0 也显示）
///  没挂标签     → 单行 "矿泉水 x 2"
List<String> prepGroupLines(PrepGroup g) {
  if (!g.byCategory) return ['${g.name} x ${g.total}'];
  return [
    '[${g.name}] 共 ${g.total}',
    '  不辣 x ${g.plainQty}',
    '  辣 x ${g.spicyQty}',
  ];
}

/// 分单明细部分：一张订单列出它的品类以及辣/不辣拆分。
/// 例："订单号<1015>, [鸡翅] 辣 x 2, 不辣 x 1"
/// 放不下时在品类边界换行（不会把品类名从中间劈开），续行缩进。
/// 该品类下的菜都没标过口味时只写总量："[沙田鸡] x 1"
List<String> prepOrderLines(Order o, int lineWidth) {
  final map = <String, List<int>>{}; // 显示名 -> [不辣, 辣]
  final marked = <String, bool>{}; // 该品类下有没有菜标过口味
  final seq = <String>[]; // 首次出现顺序，稍后按份数重排
  for (final it in o.items) {
    final cat = it.catTag.trim();
    final key = cat.isEmpty ? it.name : cat;
    if (!map.containsKey(key)) seq.add(key);
    final e = map.putIfAbsent(key, () => [0, 0]);
    if (it.isSpicy) {
      e[1] += it.quantity;
    } else {
      e[0] += it.quantity;
    }
    marked[key] = (marked[key] ?? false) || it.flavorTag.trim().isNotEmpty;
  }
  // 单内也按份数降序，跟上面的汇总顺序保持一致
  seq.sort((a, b) {
    final ta = map[a]![0] + map[a]![1];
    final tb = map[b]![0] + map[b]![1];
    final byQty = tb.compareTo(ta);
    if (byQty != 0) return byQty;
    return a.compareTo(b);
  });

  final parts = <String>[];
  for (final k in seq) {
    final e = map[k]!;
    final segs = <String>[];
    if (marked[k] ?? false) {
      if (e[1] > 0) segs.add('辣 x ${e[1]}');
      if (e[0] > 0) segs.add('不辣 x ${e[0]}');
    }
    parts.add(segs.isEmpty ? '[$k] x ${e[0] + e[1]}' : '[$k] ${segs.join(', ')}');
  }

  // 按纸宽在品类之间换行
  // 用餐方式前缀：堂食/打包一目了然（旧订单未标记用餐方式时不加前缀）
  final head = '${o.diningPrefix}订单号<${o.orderNo.padLeft(4, '0')}>';
  const indent = '      ';
  final lines = <String>[];
  var cur = head;
  var curW = _dispWidth(head);
  for (final p in parts) {
    final pw = _dispWidth(p);
    if (cur.isNotEmpty && curW + 2 + pw > lineWidth) {
      lines.add(cur);
      cur = '';
      curW = 0;
    }
    if (cur.isEmpty) {
      cur = '$indent$p';
      curW = _dispWidth(indent) + pw;
    } else {
      cur = '$cur, $p';
      curW += 2 + pw;
    }
  }
  lines.add(cur);
  return lines;
}

/// 备菜汇总小票：上半部分按品类合计（含辣/不辣拆分），下半部分逐单明细。
/// 挂了品类标签的菜（如"鸡架"下的原味/辣味）会合并成一组，
/// 没挂标签的菜沿用按菜名统计。不打印金额，只打印数量。
List<Uint8List> buildPrepSummaryEscPosBytesChunks(List<Order> orders, ReceiptSettings s) {
  final chunks = <Uint8List>[];
  final is80mm = s.paperWidth == '80mm';
  final lineWidth = is80mm ? 48 : 32;

  // ===== 两级汇总（与备菜页共用 aggregatePrep，保证屏幕与纸上一致）=====
  final groups = aggregatePrep(orders);
  var totalPieces = 0;
  for (final o in orders) {
    for (final it in o.items) {
      totalPieces += it.quantity;
    }
  }
  // 整单没有辣的单据数：厨房不用多一道工序，可以先出
  final plainOrders = orders.where((o) => o.isPlainOnly).length;
  final spicyOrders = orders.length - plainOrders;

  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final nowStr = '${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}:${two(now.minute)}';

  final sb = StringBuffer();
  sb.write('\x1B\x40'); // ESC @ 初始化打印机

  // ===== 标题：居中放大 =====
  sb.write('\x1B\x61\x01'); // 居中
  sb.write('\x1D\x21');
  sb.writeCharCode(_gsFonts[1]); // 1x2 高
  sb.writeln('== 备菜汇总 ==');
  sb.write('\x1D\x21\x00');
  sb.write('\x1B\x61\x00'); // 左对齐

  sb.writeln('时间：$nowStr');
  sb.writeln('共 ${orders.length} 单 · $totalPieces 份');
  sb.writeln('=' * lineWidth);

  // ===== 上半部分：按品类合计（1x2 放大，与厨房单一致）=====
  sb.write('\x1D\x21\x01');
  for (final g in groups) {
    for (final line in prepGroupLines(g)) {
      for (final w in _wrapLines(line, lineWidth)) {
        sb.writeln(w);
      }
    }
  }
  sb.write('\x1D\x21\x00');

  sb.writeln('-' * lineWidth);

  // ===== 下半部分：逐单明细（正常字号，信息量大省纸）=====
  for (final o in orders) {
    for (final line in prepOrderLines(o, lineWidth)) {
      for (final w in _wrapLines(line, lineWidth)) {
        sb.writeln(w);
      }
    }
  }

  sb.writeln('=' * lineWidth);
  // 无辣单标记：整单没辣的厨房可以先出
  sb.writeln('无辣 $plainOrders 单 · 含辣 $spicyOrders 单');

  // 走纸 5 行
  sb.write('\x1B\x64\x05');

  for (final l in _splitByLine(sb.toString())) {
    chunks.add(Uint8List.fromList(gbk.encode(l)));
  }

  return chunks;
}

/// emoji 等补充平面字符在 UTF-16 中是代理对（高代理区 \uD800-\uDBFF），
/// 直接用代理区范围匹配（GBK 也无法编码这些字符，删除是正确的）
final _reEmoji = RegExp(r'[\uD800-\uDBFF]');
/// 杂项符号（☀☁✿ 等 BMP 内符号，GBK 多数不可编码）
final _reSymbols = RegExp(r'[\u2600-\u27BF]');
final _reSpecial = RegExp(r'[❤★☆◆◇→←↑↓▲▽△▽]');
/// 只保留：中文、CJK 标点、全角标点、ASCII 可见字符
final _reKeep = RegExp(r'[^\u4e00-\u9fa5\u3000-\u303F\uFF00-\uFFEF\u0020-\u007E0-9\.]');

/// 过滤 emoji 和 GB2312 不支持的特殊符号
String cleanText(String s) {
  return s
      .replaceAll(_reEmoji, '')
      .replaceAll(_reSymbols, '')
      .replaceAll(_reSpecial, '')
      .replaceAll(_reKeep, '');
}

/// 确保蓝牙已连接：未连接时用上次 MAC 自动重连一次
Future<bool> ensureBluetoothConnected() async {
  try {
    final connected = await platform.invokeMethod('isConnected') as bool?;
    if (connected == true) return true;
  } catch (_) {}
  final prefs = await SharedPreferences.getInstance();
  final mac = prefs.getString('last_mac');
  if (mac == null || mac.isEmpty) return false;
  try {
    final ok = await platform.invokeMethod('connect', {'mac': mac}) as bool?;
    return ok == true;
  } catch (_) {
    return false;
  }
}

/// 按行拆分 ESC/POS 指令流
List<String> _splitByLine(String s) {
  final parts = <String>[];
  final buf = StringBuffer();
  for (final ch in s.runes) {
    buf.writeCharCode(ch);
    if (ch == 0x0A) {
      parts.add(buf.toString());
      buf.clear();
    }
  }
  if (buf.isNotEmpty) parts.add(buf.toString());
  return parts;
}

/// 分批发送 Raw Byte 数据包（解决字符串被字符集重新编码损坏位图点阵的问题）
Future<dynamic> sendEscPosBytesChunked(List<Uint8List> chunks) async {
  await SettingsStore.addLog('分批发送 Raw Bytes 开始：共 ${chunks.length} 块');
  for (var i = 0; i < chunks.length; i++) {
    var r;
    try {
      r = await platform.invokeMethod('sendBytes', {'bytes': chunks[i]});
    } catch (e) {
      await SettingsStore.addLog('第 ${i + 1}/${chunks.length} 块 invoke 异常: $e');
      r = null;
    }
    await SettingsStore.addLog('第 ${i + 1}/${chunks.length} 块 -> ${r == true ? 'OK' : '返回值: $r'}');
    if (r != true) {
      final reconnected = await ensureBluetoothConnected();
      await SettingsStore.addLog('重连结果: $reconnected');
      if (reconnected) {
        try {
          r = await platform.invokeMethod('sendBytes', {'bytes': chunks[i]});
        } catch (e) {
          await SettingsStore.addLog('第 ${i + 1} 块重发异常: $e');
          r = null;
        }
        await SettingsStore.addLog('重发第 ${i + 1} 块 -> ${r == true ? 'OK' : '返回值: $r'}');
      }
      if (r != true) {
        await SettingsStore.addLog('发送中断于第 ${i + 1} 块');
        return r;
      }
    }
    await Future.delayed(const Duration(milliseconds: 60));
  }
  await SettingsStore.addLog('分批发送 Raw Bytes 完成');
  return true;
}

String formatTime(DateTime dt) {
  final d = '${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  final t = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  return '$d $t';
}

/// 完整日期：yyyy-MM-dd（统计导出用）
String formatDate(DateTime dt) =>
    '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

// ==================== 平板检测 ====================

/// 检测设备是否为平板（最小宽度 >= 600 logical pixels）
bool isTabletDevice(BuildContext context) {
  final shortSide = MediaQuery.of(context).size.shortestSide;
  return shortSide >= 600;
}

/// 获取平板模式按钮尺寸
class TabletButtonSize {
  static const double minHeight = 64.0;
  static const double minWidth = 72.0;
  static const double fontSize = 20.0;
  static const double gridGap = 12.0;
}

// ==================== 安全与密码授权服务 ====================

class AuthService {
  static const String _kLastAuthKey = 'auth_last_verified_timestamp';
  static const String appPassword = '0818';
  static const int authValidityDays = 30;

  /// 检查当前授权是否在 30 天有效期内
  static Future<bool> isAuthValid() async {
    final prefs = await SharedPreferences.getInstance();
    final lastTime = prefs.getInt(_kLastAuthKey);
    if (lastTime == null) {
      // 首次登入，未曾验证
      return false;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final diffMillis = now - lastTime;
    final validMillis = authValidityDays * 24 * 60 * 60 * 1000;

    // 如果超过 30 天或时间被回拨异常，则需要重新验证
    if (diffMillis < 0 || diffMillis >= validMillis) {
      return false;
    }
    return true;
  }

  /// 校验密码并更新验证时间戳
  static Future<bool> verifyAndSave(String inputPassword) async {
    if (inputPassword.trim() == appPassword) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kLastAuthKey, DateTime.now().millisecondsSinceEpoch);
      return true;
    }
    return false;
  }

  /// 获取上次验证时间
  static Future<DateTime?> getLastAuthTime() async {
    final prefs = await SharedPreferences.getInstance();
    final lastTime = prefs.getInt(_kLastAuthKey);
    if (lastTime == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(lastTime);
  }

  /// 获取距离下次验证剩余天数
  static Future<int> getRemainingDays() async {
    final last = await getLastAuthTime();
    if (last == null) return 0;
    final nextDue = last.add(const Duration(days: authValidityDays));
    final diff = nextDue.difference(DateTime.now()).inDays;
    return diff < 0 ? 0 : diff;
  }

  /// 重置授权（用于测试或重新锁屏）
  static Future<void> resetAuth() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kLastAuthKey);
  }
}

// ==================== 主应用 ====================

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '蓝牙点单打印',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.blueGrey,
        useMaterial3: true,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          filled: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(minimumSize: const Size(48, 48)),
        ),
      ),
      home: const AuthGate(),
    );
  }
}

/// 授权门控组件：监控 30 天授权状态与应用前台恢复
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> with WidgetsBindingObserver {
  bool _isLoading = true;
  bool _isAuthenticated = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkAuth();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkAuth();
    }
  }

  Future<void> _checkAuth() async {
    final valid = await AuthService.isAuthValid();
    if (mounted) {
      setState(() {
        _isAuthenticated = valid;
        _isLoading = false;
      });
    }
  }

  void _onUnlockSuccess() {
    setState(() {
      _isAuthenticated = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_isAuthenticated) {
      return const MainScreen();
    }

    return PasswordLockScreen(onSuccess: _onUnlockSuccess);
  }
}

/// 密码输入锁定页面
class PasswordLockScreen extends StatefulWidget {
  final VoidCallback onSuccess;
  const PasswordLockScreen({super.key, required this.onSuccess});

  @override
  State<PasswordLockScreen> createState() => _PasswordLockScreenState();
}

class _PasswordLockScreenState extends State<PasswordLockScreen> {
  final TextEditingController _pwdCtrl = TextEditingController();
  bool _obscureText = true;
  String? _errorMsg;
  bool _isChecking = false;

  @override
  void dispose() {
    _pwdCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final input = _pwdCtrl.text.trim();
    if (input.isEmpty) {
      setState(() => _errorMsg = '请输入密码');
      return;
    }

    setState(() {
      _isChecking = true;
      _errorMsg = null;
    });

    final success = await AuthService.verifyAndSave(input);

    if (!mounted) return;

    if (success) {
      setState(() => _isChecking = false);
      widget.onSuccess();
    } else {
      setState(() {
        _isChecking = false;
        _errorMsg = '密码错误，请重新输入';
      });
      _pwdCtrl.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: Colors.blueGrey[50],
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28.0, vertical: 24.0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Card(
                elevation: 4,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                child: Padding(
                  padding: const EdgeInsets.all(28.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.lock_outline_rounded,
                          size: 38,
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        '软件安全验证',
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '首次登入或每 30 天需验证一次密码\n请输入密码以继续使用软件',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 14, color: Colors.grey[700], height: 1.4),
                      ),
                      const SizedBox(height: 28),
                      TextField(
                        controller: _pwdCtrl,
                        obscureText: _obscureText,
                        keyboardType: TextInputType.number,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _submit(),
                        style: const TextStyle(fontSize: 20, letterSpacing: 4),
                        textAlign: TextAlign.center,
                        decoration: InputDecoration(
                          hintText: '请输入4位密码',
                          hintStyle: const TextStyle(letterSpacing: 0, fontSize: 16),
                          prefixIcon: const Icon(Icons.password_rounded),
                          suffixIcon: IconButton(
                            icon: Icon(_obscureText ? Icons.visibility_off : Icons.visibility),
                            onPressed: () => setState(() => _obscureText = !_obscureText),
                          ),
                          errorText: _errorMsg,
                        ),
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: theme.colorScheme.primary,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          onPressed: _isChecking ? null : _submit,
                          child: _isChecking
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                                )
                              : const Text('验证并解锁', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ==================== 底部导航主页面 ====================

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;
  static const int _prepIndex = 3; // 备菜页在导航中的位置
  static const int _entryIndex = 1; // 新建订单页在导航中的位置

  /// 切到备菜页时自增，通知其重新加载最新订单
  final ValueNotifier<int> _prepRefresh = ValueNotifier<int>(0);

  /// 切到新建订单页时自增，通知其重新加载桌号（IndexedStack 页面常驻，
  /// 在【设置】→ 桌号管理里增删后需要重新读一次）
  final ValueNotifier<int> _entryRefresh = ValueNotifier<int>(0);

  late final List<Widget> _pages = [
    const BluetoothPage(),
    OrderEntryPage(refreshSignal: _entryRefresh),
    const OrderHistoryPage(),
    PrepPage(refreshSignal: _prepRefresh),
    const SettingsPage(),
  ];

  void _onTabSelected(int i) {
    setState(() => _currentIndex = i);
    if (i == _prepIndex) _prepRefresh.value++;
    if (i == _entryIndex) _entryRefresh.value++;
  }

  @override
  void dispose() {
    _prepRefresh.dispose();
    _entryRefresh.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isLandscapeTablet = isTabletDevice(context) && size.width > size.height;

    if (isLandscapeTablet) {
      // 横屏平板模式：左侧 NavigationRail 侧边栏，右侧页面内容
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _currentIndex,
              onDestinationSelected: _onTabSelected,
              labelType: NavigationRailLabelType.all,
              leading: const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Icon(Icons.receipt_long, size: 36, color: Colors.blueGrey),
              ),
              destinations: const [
                NavigationRailDestination(
                  icon: Icon(Icons.bluetooth_outlined, size: 28),
                  selectedIcon: Icon(Icons.bluetooth, size: 28, color: Colors.blueGrey),
                  label: Text('蓝牙', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.add_circle_outline, size: 28),
                  selectedIcon: Icon(Icons.add_circle, size: 28, color: Colors.blueGrey),
                  label: Text('新建订单', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.history_outlined, size: 28),
                  selectedIcon: Icon(Icons.history, size: 28, color: Colors.blueGrey),
                  label: Text('历史', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.restaurant_menu, size: 28),
                  selectedIcon: Icon(Icons.restaurant_menu, size: 28, color: Colors.blueGrey),
                  label: Text('备菜', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.settings_outlined, size: 28),
                  selectedIcon: Icon(Icons.settings, size: 28, color: Colors.blueGrey),
                  label: Text('设置', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            const VerticalDivider(thickness: 1, width: 1),
            Expanded(
              child: IndexedStack(index: _currentIndex, children: _pages),
            ),
          ],
        ),
      );
    }

    // 手机 & 竖屏平板模式：底部标准 NavigationBar
    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: _onTabSelected,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.bluetooth_outlined),
            selectedIcon: Icon(Icons.bluetooth),
            label: '蓝牙',
          ),
          NavigationDestination(
            icon: Icon(Icons.add_circle_outline),
            selectedIcon: Icon(Icons.add_circle),
            label: '新建订单',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_outlined),
            selectedIcon: Icon(Icons.history),
            label: '历史',
          ),
          NavigationDestination(
            icon: Icon(Icons.restaurant_menu),
            selectedIcon: Icon(Icons.restaurant_menu),
            label: '备菜',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }
}

// ==================== 蓝牙连接页面 ====================

class BluetoothPage extends StatefulWidget {
  const BluetoothPage({super.key});

  @override
  State<BluetoothPage> createState() => _BluetoothPageState();
}

class _BluetoothPageState extends State<BluetoothPage> {
  List<Map<String, dynamic>> _devices = [];
  bool _loading = false;
  String _statusText = '未连接';
  Color _statusColor = Colors.grey;
  String? _lastMac;
  Timer? _statusTimer;

  @override
  void initState() {
    super.initState();
    platform.setMethodCallHandler(_onNativeEvent);
    _loadLastDevice();
    _checkConnection();
    // 定时刷新连接状态：打印机可能空闲断开，页面需实时反映真实状态
    // （IndexedStack 页面常驻，initState 只跑一次，没有轮询会一直显示陈旧的"已连接"）
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) => _checkConnection());
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    platform.setMethodCallHandler(null);
    super.dispose();
  }

  /// 接收原生主动推送：新设备发现 / 扫描结束 / 权限授予后自动重扫
  Future<dynamic> _onNativeEvent(MethodCall call) async {
    switch (call.method) {
      case 'onDeviceFound':
        final args = call.arguments as Map?;
        if (args != null) _addDevice(Map<String, dynamic>.from(args));
        break;
      case 'onScanFinished':
        if (mounted) setState(() => _loading = false);
        break;
      case 'onScanResult':
        final list = call.arguments as List? ?? [];
        if (mounted) {
          setState(() {
            _devices = _sortDevices(list.map((e) => Map<String, dynamic>.from(e as Map)).toList());
            _loading = false;
          });
        }
        break;
    }
    return null;
  }

  /// 设备排序：打印机关键词（MPT/HPRT/B3/NIIMBOT/精臣/汉印等）排前面，方便快速找到打印机
  List<Map<String, dynamic>> _sortDevices(List<Map<String, dynamic>> list) {
    const keywords = ['mpt', 'hprt', 'b3', 'niimbot', '精臣', '汉印', '芯烨', '打印机', 'print'];
    final sorted = List<Map<String, dynamic>>.from(list);
    sorted.sort((a, b) {
      final na = ((a['name'] as String?) ?? '').toLowerCase();
      final nb = ((b['name'] as String?) ?? '').toLowerCase();
      final sa = keywords.any((k) => na.contains(k)) ? 0 : 1;
      final sb = keywords.any((k) => nb.contains(k)) ? 0 : 1;
      if (sa != sb) return sa.compareTo(sb);
      return na.compareTo(nb);
    });
    return sorted;
  }

  void _addDevice(Map<String, dynamic> d) {
    final mac = d['address'] as String? ?? '';
    if (mac.isEmpty || _devices.any((e) => e['address'] == mac)) return;
    if (mounted) setState(() => _devices.add(d));
  }

  /// 设备名为空时显示 mac 后几位，方便区分
  String _deviceDisplayName(Map<String, dynamic> d) {
    final name = (d['name'] as String?)?.trim() ?? '';
    if (name.isNotEmpty && name != '未知设备') return name;
    final mac = d['address'] as String? ?? '';
    final short = mac.length >= 5 ? mac.substring(mac.length - 5) : mac;
    return '未知设备 $short';
  }

  Future<void> _loadLastDevice() async {
    final prefs = await SharedPreferences.getInstance();
    _lastMac = prefs.getString('last_mac');
    if (_lastMac != null && _lastMac!.isNotEmpty) {
      // 已连接时跳过自动重连，避免每次进入页面都断线重连
      try {
        final connected = await platform.invokeMethod('isConnected');
        if (connected == true && mounted) {
          setState(() {
            _statusText = '已连接';
            _statusColor = Colors.green;
          });
          return;
        }
      } catch (_) {}
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) _connectToDevice(_lastMac!);
      });
    }
  }

  Future<void> _checkConnection() async {
    try {
      final connected = await platform.invokeMethod('isConnected');
      if (!mounted) return;
      setState(() {
        if (connected == true) {
          _statusText = '已连接';
          _statusColor = Colors.green;
        } else {
          _statusText = '未连接';
          _statusColor = Colors.grey;
        }
      });
    } catch (_) {}
  }

  Future<void> _startScan() async {
    setState(() {
      _loading = true;
      _devices = [];
    });
    try {
      final list = await platform.invokeMethod('startScan') as List?;
      if (mounted) {
        setState(() {
          _devices = _sortDevices(
              list?.map((e) => Map<String, dynamic>.from(e as Map)).toList() ?? []);
        });
      }
      // 原生 discovery 结束后会推送 onScanFinished；这里做 12 秒兜底防卡圈
      Future.delayed(const Duration(seconds: 12), () {
        if (mounted && _loading) setState(() => _loading = false);
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        _showError('扫描失败: $e');
      }
    }
  }

  Future<void> _connectToDevice(String mac) async {
    if (!mounted) return;
    // 已连接同一台设备时直接保持，不重复断开重连
    if (_lastMac == mac) {
      try {
        final connected = await platform.invokeMethod('isConnected');
        if (connected == true) {
          setState(() {
            _statusText = '已连接';
            _statusColor = Colors.green;
          });
          return;
        }
      } catch (_) {}
    }
    setState(() => _statusText = '连接中...');
    try {
      final ok = await platform.invokeMethod('connect', {'mac': mac}) as bool?;
      if (!mounted) return;
      if (ok == true) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('last_mac', mac);
        setState(() {
          _statusText = '已连接';
          _statusColor = Colors.green;
          _lastMac = mac;
        });
        if (mounted) _showInfo('蓝牙打印机连接成功');
      } else {
        setState(() {
          _statusText = '连接失败';
          _statusColor = Colors.red;
        });
        if (mounted) _showError('连接失败，请检查：打印机已开机、蓝牙已配对、纸张已装好');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusText = '连接失败';
        _statusColor = Colors.red;
      });
      if (mounted) _showError('连接异常: $e');
    }
  }

  Future<void> _disconnect() async {
    try {
      await platform.invokeMethod('disconnect');
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('last_mac');
      setState(() {
        _statusText = '未连接';
        _statusColor = Colors.grey;
        _lastMac = null;
      });
      if (mounted) _showInfo('已断开连接');
    } catch (e) {}
  }

  /// 打印测试页：发送最小 ESC/POS 指令（初始化+两行文本+走纸），
  /// 用于区分"蓝牙数据链路问题"和"小票模板问题"
  Future<void> _printTestPage() async {
    final buf = StringBuffer()
      ..write('\x1B\x40') // ESC @ 初始化
      ..writeln('PRINTER TEST OK')
      ..writeln('蓝牙打印测试 12345')
      ..write('\x1B\x61\x01') // ESC a 1 居中
      ..writeln('居中测试：你好')
      ..write('\x1B\x61\x00') // ESC a 0 左对齐
      ..write('\x1D\x21\x11') // GS ! 2x2 放大
      ..writeln('放大测试')
      ..write('\x1D\x21\x00') // 恢复正常
      ..write('\x1D\x21\x08') // GS ! 0x08 1x1+加粗（bit3）
      ..writeln('加粗测试：BOLD')
      ..write('\x1D\x21\x00') // 取消加粗
      ..writeln('-' * 32) // 满行分隔线
      ..writeln('对齐模拟：菜品   数量  单价')
      ..write('\x1B\x64\x05'); // 走纸 5 行
    try {
      final r = await platform.invokeMethod('sendData', {'data': buf.toString()});
      if (r == true) {
        if (mounted) _showInfo('测试指令已发送，请观察打印机是否出纸');
      } else if (mounted) {
        _showError('发送失败：$r');
      }
    } catch (e) {
      if (mounted) _showError('发送异常: $e');
    }
  }

  void _showInfo(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
  }

  @override
  Widget build(BuildContext context) {
    final isTablet = isTabletDevice(context);
    return Scaffold(
      appBar: AppBar(title: const Text('蓝牙连接')),
      body: Padding(
        padding: EdgeInsets.all(isTablet ? 24.0 : 16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 状态卡片
            Card(
              elevation: 2,
              child: Padding(
                padding: EdgeInsets.all(isTablet ? 32.0 : 24.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.bluetooth_connected, size: isTablet ? 56 : 44, color: _statusColor),
                        SizedBox(width: isTablet ? 24 : 16),
                        Text(_statusText,
                            style: TextStyle(fontSize: isTablet ? 26 : 22, fontWeight: FontWeight.w600)),
                      ],
                    ),
                    if (_statusColor == Colors.green)
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.red,
                          minimumSize: Size(isTablet ? 120 : 72, 64),
                          padding: EdgeInsets.symmetric(horizontal: isTablet ? 32 : 24),
                        ),
                        onPressed: _disconnect,
                        child: Text('断开', style: TextStyle(fontSize: isTablet ? 20 : 16)),
                      ),
                  ],
                ),
              ),
            ),
            if (_statusColor == Colors.green) ...[
              SizedBox(height: isTablet ? 20 : 12),
              // 打印测试页：发送最小 ESC/POS 指令，验证数据链路是否真的可用
              OutlinedButton.icon(
                onPressed: _printTestPage,
                icon: Icon(Icons.print_outlined, size: isTablet ? 28 : 24),
                label: Text('打印测试页', style: TextStyle(fontSize: isTablet ? 20 : 16)),
                style: OutlinedButton.styleFrom(
                    minimumSize: Size.fromHeight(isTablet ? 72 : 48),
                    textStyle: TextStyle(fontSize: isTablet ? 20 : 16)),
              ),
            ],
            SizedBox(height: isTablet ? 24 : 16),

            // 扫描按钮
            SizedBox(
              height: isTablet ? 72 : 56,
              child: ElevatedButton.icon(
                onPressed: _loading ? null : _startScan,
                icon: _loading
                    ? SizedBox(width: isTablet ? 32 : 24, height: isTablet ? 32 : 24, child: CircularProgressIndicator(strokeWidth: 2.5))
                    : Icon(Icons.refresh, size: isTablet ? 32 : 26),
                label: Text(_loading ? '扫描中...' : '扫描已配对设备',
                    style: TextStyle(fontSize: isTablet ? 22 : 18)),
                style: ElevatedButton.styleFrom(
                    minimumSize: Size.fromHeight(isTablet ? 72 : 56),
                    textStyle: TextStyle(fontSize: isTablet ? 22 : 18)),
              ),
            ),
            SizedBox(height: isTablet ? 20 : 12),
            Text('提示：请确保精臣B3打印机已通过手机系统蓝牙配对\n扫描时也会自动发现附近未配对的新设备',
                style: TextStyle(color: Colors.grey, fontSize: isTablet ? 16 : 13), textAlign: TextAlign.center),
            SizedBox(height: isTablet ? 20 : 12),

            // 设备列表（所有设备都可点击连接，不再限制设备名含 B3）
            Expanded(
              child: _devices.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.bluetooth_searching, size: isTablet ? 96 : 72, color: Colors.grey),
                          SizedBox(height: isTablet ? 24 : 16),
                          Text('点击"扫描已配对设备"\n查找已配对的精臣B3打印机',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.grey, fontSize: isTablet ? 20 : 16)),
                        ],
                      ),
                    )
                  : ListView.builder(
                      itemCount: _devices.length,
                      itemBuilder: (context, index) {
                        final d = _devices[index];
                        final mac = d['address'] as String? ?? '';
                        final isDiscovered = d['type'] == 'discovered';
                        return Card(
                          margin: EdgeInsets.only(bottom: isTablet ? 12 : 8),
                          child: ListTile(
                            leading: Icon(Icons.print, color: Colors.blueGrey, size: isTablet ? 44 : 32),
                            title: Text(_deviceDisplayName(d),
                                style: TextStyle(fontSize: isTablet ? 22 : 18)),
                            subtitle: Text('$mac${isDiscovered ? '（新发现）' : ''}',
                                style: TextStyle(fontSize: isTablet ? 16 : 13)),
                            trailing: FilledButton(
                              style: FilledButton.styleFrom(
                                minimumSize: Size(isTablet ? 100 : 72, isTablet ? 56 : 40),
                                padding: EdgeInsets.symmetric(horizontal: isTablet ? 24 : 16),
                              ),
                              onPressed: () => _connectToDevice(mac),
                              child: Text('连接', style: TextStyle(fontSize: isTablet ? 20 : 16)),
                            ),
                            onTap: () => _connectToDevice(mac),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== 新建订单页面（外卖版）====================

class OrderEntryPage extends StatefulWidget {
  const OrderEntryPage({super.key, this.refreshSignal});

  /// 切换到本页时由 MainScreen 自增，通知重新加载桌号（设置页可能刚增删过）
  final ValueNotifier<int>? refreshSignal;

  @override
  State<OrderEntryPage> createState() => _OrderEntryPageState();
}

class _OrderEntryPageState extends State<OrderEntryPage> {
  final _noteCtrl = TextEditingController();
  final List<OrderItem> _items = [];
  List<MenuItem> _menu = [];
  List<TagDef> _tags = []; // 标签库（点单时把标签快照进订单明细）
  bool _printing = false;
  int _nextNo = 1; // 下一单号预览
  String _currency = 'RM'; // 货币符号（设置页可配置）
  double _uiScale = 1.0; // UI 缩放比例（0.8 ~ 1.6）
  // 用餐方式：默认堂食；堂食时可选桌号（桌号列表在【设置】→ 桌号管理里维护）
  String _diningType = 'dinein';
  String _tableNo = '';
  List<String> _tableNos = [];

  double get _total => _items.fold(0.0, (s, i) => s + i.subtotal);

  @override
  void initState() {
    super.initState();
    widget.refreshSignal?.addListener(_onRefreshSignal);
    _loadData();
  }

  @override
  void dispose() {
    widget.refreshSignal?.removeListener(_onRefreshSignal);
    _noteCtrl.dispose();
    super.dispose();
  }

  void _onRefreshSignal() => _loadData();

  Future<void> _loadData() async {
    final menu = await SettingsStore.loadMenu();
    final tags = await SettingsStore.loadTags();
    final next = await SettingsStore.getCurrentNo();
    final currency = await SettingsStore.getCurrency();
    final scale = await SettingsStore.getUiScale();
    final tableNos = await SettingsStore.getTableNos();
    if (mounted) {
      setState(() {
        _menu = menu;
        _tags = tags;
        _nextNo = next;
        _currency = currency;
        _uiScale = scale;
        _tableNos = tableNos;
        // 设置页可能删掉了当前选中的桌号 → 回退为"不指定"
        if (!_tableNos.contains(_tableNo)) _tableNo = '';
      });
    }
  }

  /// 用餐方式选择：堂食（默认）/ 打包；选堂食时多一个桌号下拉框。
  /// 打印时会在小票最顶部输出 "堂食(Table:65)" / "打包"。
  Widget _buildDiningSelector(double s) {
    return Container(
      padding: EdgeInsets.all(12 * s),
      decoration: BoxDecoration(
        color: Colors.orange[50],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.orange[200]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('用餐方式',
              style: TextStyle(fontSize: 15 * s, fontWeight: FontWeight.bold)),
          Row(
            children: [
              Expanded(
                child: RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  value: 'dinein',
                  groupValue: _diningType,
                  onChanged: (v) => setState(() => _diningType = v ?? 'dinein'),
                  title: Text('堂食',
                      style: TextStyle(fontSize: 16 * s, fontWeight: FontWeight.bold)),
                ),
              ),
              Expanded(
                child: RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  value: 'takeaway',
                  groupValue: _diningType,
                  onChanged: (v) => setState(() {
                    _diningType = v ?? 'dinein';
                    // 打包单不保留桌号，避免打印出 "打包(Table:65)"
                    if (_diningType != 'dinein') _tableNo = '';
                  }),
                  title: Text('打包',
                      style: TextStyle(fontSize: 16 * s, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
          if (_diningType == 'dinein') ...[
            SizedBox(height: 4 * s),
            if (_tableNos.isEmpty)
              Text('暂无桌号，可先在【设置】→ 桌号管理里添加；不选桌号则只打印"堂食"',
                  style: TextStyle(fontSize: 12 * s, color: Colors.grey))
            else
              DropdownButtonFormField<String>(
                value: _tableNos.contains(_tableNo) ? _tableNo : '',
                isDense: true,
                decoration: InputDecoration(
                  labelText: '桌号',
                  isDense: true,
                  border: const OutlineInputBorder(),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 10 * s, vertical: 10 * s),
                ),
                items: [
                  const DropdownMenuItem(value: '', child: Text('不指定桌号')),
                  for (final t in _tableNos)
                    DropdownMenuItem(value: t, child: Text('$t 号桌')),
                ],
                onChanged: (v) => setState(() => _tableNo = v ?? ''),
              ),
          ],
        ],
      ),
    );
  }

  Future<void> _zoomIn() async {
    final newScale = (_uiScale + 0.1).clamp(0.8, 1.6);
    final rounded = (newScale * 10).round() / 10;
    setState(() => _uiScale = rounded);
    await SettingsStore.setUiScale(rounded);
  }

  Future<void> _zoomOut() async {
    final newScale = (_uiScale - 0.1).clamp(0.8, 1.6);
    final rounded = (newScale * 10).round() / 10;
    setState(() => _uiScale = rounded);
    await SettingsStore.setUiScale(rounded);
  }

  Future<void> _resetZoom() async {
    setState(() => _uiScale = 1.0);
    await SettingsStore.setUiScale(1.0);
  }

  /// 按菜单项生成订单明细：把品类/口味标签和"是否辣"一起快照进去，
  /// 以后改菜单或改标签名都不会影响已经下过的单。
  OrderItem _itemFromMenu(MenuItem m, int qty) => OrderItem(
        name: m.name,
        price: m.price,
        quantity: qty,
        isSpicy: SettingsStore.isSpicyFlavor(_tags, m.flavorTag),
        catTag: m.catTag,
        flavorTag: m.flavorTag,
      );

  int _qtyOf(MenuItem m) {
    for (final it in _items) {
      if (it.name == m.name && it.price == m.price) return it.quantity;
    }
    return 0;
  }

  void _increase(MenuItem m) {
    setState(() {
      final idx = _items.indexWhere((it) => it.name == m.name && it.price == m.price);
      if (idx >= 0) {
        _items[idx] = _itemFromMenu(m, _items[idx].quantity + 1);
      } else {
        _items.add(_itemFromMenu(m, 1));
      }
    });
  }

  void _decrease(MenuItem m) {
    setState(() {
      final idx = _items.indexWhere((it) => it.name == m.name && it.price == m.price);
      if (idx >= 0) {
        final q = _items[idx].quantity - 1;
        if (q <= 0) {
          _items.removeAt(idx);
        } else {
          _items[idx] = _itemFromMenu(m, q);
        }
      }
    });
  }

  /// 点击菜单项 → 弹出对话框直接输入数量
  Future<void> _editQtyDialog(MenuItem m) async {
    final cur = _qtyOf(m);
    final ctrl = TextEditingController(text: cur == 0 ? '1' : '$cur');
    final qty = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${m.name}  ${fmt(m.price)} $_currency/份'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          style: const TextStyle(fontSize: 22),
          decoration: const InputDecoration(labelText: '数量'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, int.tryParse(ctrl.text.trim()) ?? 0),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (qty == null || qty <= 0) return;
    setState(() {
      final idx = _items.indexWhere((it) => it.name == m.name && it.price == m.price);
      if (idx >= 0) {
        _items[idx] = _itemFromMenu(m, qty);
      } else {
        _items.add(_itemFromMenu(m, qty));
      }
    });
  }

  void _removeItem(int idx) {
    setState(() => _items.removeAt(idx));
  }

  Future<void> _saveAndPrint() async {
    await SettingsStore.addLog('--- 新建订单打印开始 ---');
    if (_items.isEmpty) {
      if (mounted) _showMsg('请先选择菜品');
      return;
    }
    // 检查蓝牙；未连接时自动重连一次（打印机可能已空闲断开）
    // 仍未连接：弹窗提示，用户可选择「直接下单」——不打印，仅保存订单
    var directOrderOnly = false;
    if (!await ensureBluetoothConnected()) {
      await SettingsStore.addLog('蓝牙未连接且自动重连失败');
      if (!mounted) return;
      final direct = await showDialog<bool>(
        context: context,
        builder: (_) => _bluetoothErrorDialog(),
      );
      if (direct != true || !mounted) return;
      directOrderOnly = true;
      await SettingsStore.addLog('蓝牙未连接，用户选择直接下单（不打印）');
    }
    if (!directOrderOnly) {
      await SettingsStore.addLog('蓝牙连接正常，开始下单');
    }

    // 顺序取下一单号（01、02、03...）
    final no = await SettingsStore.takeNextNo();
    final order = Order(
      id: 'DD${DateTime.now().millisecondsSinceEpoch}',
      orderNo: formatNo(no),
      items: List.from(_items),
      total: _total,
      note: _noteCtrl.text.trim(),
      time: DateTime.now(),
      diningType: _diningType,
      tableNo: _diningType == 'dinein' ? _tableNo : '',
    );

    // 保存历史
    await _saveOrder(order);

    // 直接下单（蓝牙未连接）：只保存订单与单号，不打印
    if (directOrderOnly) {
      if (mounted) {
        setState(() {
          _items.clear();
          _nextNo = no + 1;
        });
        _noteCtrl.clear();
      }
      await SettingsStore.addLog('直接下单成功（未打印）：单号 ${order.orderNo}');
      if (mounted) {
        _showMsg('单号 ${order.orderNo} 已下单（未打印），可在【历史】页补打');
      }
      return;
    }

    // 生成并发送 ESC/POS 指令
    setState(() => _printing = true);
    try {
      final settings = await loadReceiptSettings();
      // 第一张：发票
      final chunks = buildEscPosBytesChunks(order, settings);
      final ok = await sendEscPosBytesChunked(chunks);

      if (ok == true && mounted) {
        await SettingsStore.addLog('发票打印成功');
        setState(() {
          _items.clear();
          _nextNo = no + 1;
        });
        _noteCtrl.clear();
        _showMsg('单号 ${order.orderNo} 发票打印成功！');
        
        // 询问接下来打印什么
        final choice = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('发票打印完成'),
            content: Text('单号 ${order.orderNo} 发票已成功打印。\n请选择接下来要执行的操作：'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, 'none'), child: const Text('完成 (不打印)')),
              OutlinedButton(
                  onPressed: () => Navigator.pop(ctx, 'invoice'), child: const Text('再打一张发票')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, 'kitchen'), child: const Text('打印厨房单')),
            ],
          ),
        );
        if (choice == 'invoice' && mounted) {
          await _printOrder(order, isKitchen: false);
        } else if (choice == 'kitchen' && mounted) {
          await _printOrder(order, isKitchen: true);
        }
      } else if (mounted) {
        await SettingsStore.addLog('发票打印失败，sendEscPosBytesChunked 返回: $ok');
        _showPrintError(ok is String ? ok : null);
      }
    } catch (e) {
      await SettingsStore.addLog('打印异常: $e');
      if (mounted) _showPrintError('$e');
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  /// 补打一张小票（不重复下单号）
  Future<bool> _printOrder(Order o, {bool isKitchen = false}) async {
    if (!await ensureBluetoothConnected()) {
      await SettingsStore.addLog('补打：蓝牙未连接且自动重连失败');
      if (mounted) {
        showDialog(
            context: context,
            builder: (_) => AlertDialog(
                  title: const Text('蓝牙未连接'),
                  content: const Text('自动重连失败，请检查打印机是否已开机、蓝牙是否已配对'),
                  actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('确定'))],
                ));
      }
      return false;
    }
    try {
      final settings = await loadReceiptSettings();
      final chunks = isKitchen 
          ? buildKitchenEscPosBytesChunks(o, settings)
          : buildEscPosBytesChunks(o, settings);
      final ok = await sendEscPosBytesChunked(chunks);
      if (ok == true) {
        await SettingsStore.addLog('补打成功：单号 ${o.orderNo}');
        if (mounted) _showMsg('已补打一张 ${isKitchen ? "厨房单" : "发票"}（单号 ${o.orderNo}）');
        return true;
      } else {
        await SettingsStore.addLog('补打失败：单号 ${o.orderNo}，返回: $ok');
        if (mounted) _showMsg('补打失败：${ok is String ? ok : '请检查打印机状态'}');
        return false;
      }
    } catch (e) {
      await SettingsStore.addLog('补打异常: $e');
      if (mounted) _showMsg('补打异常: $e');
      return false;
    }
  }

  Future<void> _saveOrder(Order o) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('orders') ?? [];
    list.add(encodeOrder(o));
    await prefs.setStringList('orders', list);
  }

  void _showMsg(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _showPrintError([String? detail]) {
    showDialog(
        context: context,
        builder: (_) => AlertDialog(
              title: const Text('打印失败'),
              content: Text(detail != null
                  ? '请检查打印机状态：\n• 打印机是否已开机\n• 蓝牙是否已连接\n• 纸张是否装好\n\n技术信息：$detail'
                  : '请检查打印机状态：\n• 打印机是否已开机\n• 蓝牙是否已连接\n• 纸张是否装好\n• 打印机蓝牙是否已配对'),
              actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('确定'))],
            ));
  }

  /// 蓝牙未连接提示：可返回去连接，也可直接下单（不打印）
  /// 返回 true = 直接下单，false/null = 取消
  Widget _bluetoothErrorDialog() => AlertDialog(
        title: const Text('蓝牙未连接'),
        content: const Text('自动重连失败，请检查：\n• 打印机是否已开机\n• 是否在有效距离内（10米）\n• 手机系统蓝牙是否已配对\n\n可回到【蓝牙】页面手动连接后重试，\n或点「直接下单」先保存订单（之后可在【历史】页补打）。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.receipt_long),
            label: const Text('直接下单（不打印）'),
          ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final isTablet = isTabletDevice(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('新建订单'),
        actions: [
          IconButton(
            icon: const Icon(Icons.zoom_out),
            tooltip: '缩小界面',
            onPressed: _uiScale > 0.8 ? _zoomOut : null,
          ),
          InkWell(
            onTap: _resetZoom,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              child: Center(
                child: Text(
                  '${(_uiScale * 100).round()}%',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.zoom_in),
            tooltip: '放大界面',
            onPressed: _uiScale < 1.6 ? _zoomIn : null,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _buildTabletOrPhoneBody(context, isTablet),
    );
  }

  /// 平板布局：左侧菜单网格 + 右侧订单清单（横屏）或上下分栏（竖屏）
  Widget _buildTabletOrPhoneBody(BuildContext context, bool isTablet) {
    if (!isTablet) {
      return _buildPhoneBody();
    }
    return _buildTabletBody(context);
  }

  /// 手机标准布局
  Widget _buildPhoneBody() {
    final s = _uiScale;
    return SingleChildScrollView(
      padding: EdgeInsets.all(16.0 * s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 0. 用餐方式（堂食 / 打包）+ 堂食桌号（页面最顶端）
          _buildDiningSelector(s),
          SizedBox(height: 14 * s),

          // 1. 总金额（最上面）
          Container(
            padding: EdgeInsets.all(16 * s),
            decoration: BoxDecoration(
                color: Colors.blueGrey[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blueGrey)),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('总金额', style: TextStyle(fontSize: 20 * s, fontWeight: FontWeight.bold)),
              Text('${fmt(_total)} $_currency',
                  style: TextStyle(
                      fontSize: 24 * s, fontWeight: FontWeight.bold, color: Colors.red)),
            ]),
          ),
          SizedBox(height: 14 * s),

          // 2. 保存并打印小票（总金额下面）
          SizedBox(
            height: 60 * s,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green[700], minimumSize: Size.fromHeight(60 * s)),
              onPressed: _printing ? null : _saveAndPrint,
              child: _printing
                  ? SizedBox(
                      height: 28 * s, width: 28 * s, child: const CircularProgressIndicator(color: Colors.white, strokeWidth: 3))
                  : Text('保存并打印小票', style: TextStyle(fontSize: 20 * s, color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ),
          SizedBox(height: 20 * s),

          // 3. 菜单选择
          Text('选择菜品（点菜单项可直接输入数量）',
              style: TextStyle(fontSize: 15 * s, fontWeight: FontWeight.bold)),
          SizedBox(height: 8 * s),
          if (_menu.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(vertical: 12 * s),
              child: Text('暂无菜单，请先在【设置】页添加菜品和价格',
                  style: TextStyle(color: Colors.grey, fontSize: 14 * s)),
            )
          else
            ..._menu.map((m) {
              final qty = _qtyOf(m);
              return Card(
                margin: EdgeInsets.only(bottom: 6 * s),
                child: ListTile(
                  title: Text(m.name, style: TextStyle(fontSize: 17 * s, fontWeight: FontWeight.w600)),
                  subtitle: Text('${fmt(m.price)} $_currency',
                      style: TextStyle(fontSize: 13 * s, color: Colors.grey)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        iconSize: 26 * s,
                        icon: const Icon(Icons.remove_circle_outline, color: Colors.orange),
                        onPressed: qty > 0 ? () => _decrease(m) : null,
                      ),
                      SizedBox(
                        width: 32 * s,
                        child: Text('$qty',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 17 * s, fontWeight: FontWeight.bold)),
                      ),
                      IconButton(
                        iconSize: 26 * s,
                        icon: const Icon(Icons.add_circle, color: Colors.green),
                        onPressed: () => _increase(m),
                      ),
                    ],
                  ),
                  onTap: () => _editQtyDialog(m),
                ),
              );
            }),
          SizedBox(height: 16 * s),

          // 4. 已选菜品清单
          if (_items.isNotEmpty) ...[
            Text('已选菜品', style: TextStyle(fontSize: 15 * s, fontWeight: FontWeight.bold)),
            SizedBox(height: 8 * s),
            ..._items.asMap().entries.map((e) {
              final idx = e.key;
              final item = e.value;
              return Card(
                margin: EdgeInsets.only(bottom: 6 * s),
                child: ListTile(
                  title: Text(item.name, style: TextStyle(fontSize: 18 * s)),
                  subtitle: Text('${item.quantity} × ${fmt(item.price)} = ${fmt(item.subtotal)} $_currency',
                      style: TextStyle(fontSize: 14 * s)),
                  trailing: IconButton(
                    iconSize: 28 * s,
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    onPressed: () => _removeItem(idx),
                  ),
                ),
              );
            }),
            SizedBox(height: 8 * s),
          ],

          // 5. 备注（选填）
          Text('备注（选填）', style: TextStyle(fontSize: 15 * s, fontWeight: FontWeight.bold)),
          SizedBox(height: 4 * s),
          TextField(
              controller: _noteCtrl,
              maxLines: 2,
              style: TextStyle(fontSize: 18 * s),
              decoration: const InputDecoration(hintText: '备注（选填，如：少辣、不要葱）')),
          SizedBox(height: 20 * s),

          // 6. 本单号（最底部）
          Container(
            padding: EdgeInsets.all(16 * s),
            decoration: BoxDecoration(
                color: Colors.blueGrey[700], borderRadius: BorderRadius.circular(10)),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('本单号',
                    style: TextStyle(fontSize: 18 * s, color: Colors.white, fontWeight: FontWeight.bold)),
                Text(formatNo(_nextNo),
                    style: TextStyle(
                        fontSize: 30 * s, color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 4)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 平板布局：根据屏幕方向选择左右分栏或上下分栏
  Widget _buildTabletBody(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isLandscape = size.width > size.height;
    final s = _uiScale;

    if (isLandscape) {
      // 横屏平板：左右分栏
      return Row(
        children: [
          // 左侧：菜单选择区
          Expanded(
            flex: 3,
            child: _buildTabletMenuGrid(context),
          ),
          // 右侧：订单清单 + 操作按钮
          Expanded(
            flex: 2,
            child: _buildTabletOrderPanel(context),
          ),
        ],
      );
    } else {
      // 竖屏平板：上下布局
      return Column(
        children: [
          // 顶部：订单摘要和操作按钮
          Container(
            color: Colors.blueGrey[50],
            padding: EdgeInsets.all(16 * s),
            child: Column(
              children: [
                // 0. 用餐方式（堂食 / 打包）+ 堂食桌号（页面最顶端）
                _buildDiningSelector(s),
                SizedBox(height: 10 * s),
                // 1. 总金额
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('总金额', style: TextStyle(fontSize: 22 * s, fontWeight: FontWeight.bold)),
                    Text('${fmt(_total)} $_currency',
                        style: TextStyle(fontSize: 28 * s, fontWeight: FontWeight.bold, color: Colors.red)),
                  ],
                ),
                SizedBox(height: 10 * s),
                // 2. 打印按钮 - 大按钮
                SizedBox(
                  height: TabletButtonSize.minHeight * s,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green[700],
                      minimumSize: const Size.fromWidth(double.infinity),
                    ),
                    onPressed: _printing ? null : _saveAndPrint,
                    child: _printing
                        ? SizedBox(
                            height: 32 * s, width: 32 * s, child: const CircularProgressIndicator(color: Colors.white, strokeWidth: 3))
                        : Text('保存并打印小票', style: TextStyle(fontSize: 22 * s, color: Colors.white, fontWeight: FontWeight.bold)),
                  ),
                ),
                SizedBox(height: 8 * s),
                // 3. 备注输入
                TextField(
                  controller: _noteCtrl,
                  maxLines: 2,
                  style: TextStyle(fontSize: 18 * s),
                  decoration: const InputDecoration(
                    hintText: '备注（选填，如：少辣、不要葱）',
                    border: OutlineInputBorder(),
                  ),
                ),
                SizedBox(height: 8 * s),
                // 4. 单号显示
                Container(
                  padding: EdgeInsets.all(12 * s),
                  decoration: BoxDecoration(
                    color: Colors.blueGrey[700],
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('本单号',
                          style: TextStyle(fontSize: 20 * s, color: Colors.white, fontWeight: FontWeight.bold)),
                      SizedBox(width: 16 * s),
                      Text(formatNo(_nextNo),
                          style: TextStyle(
                              fontSize: 36 * s, color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 4)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // 底部：菜单网格
          Expanded(child: _buildTabletMenuGrid(context)),
        ],
      );
    }
  }

  /// 平板菜单网格布局
  Widget _buildTabletMenuGrid(BuildContext context) {
    final s = _uiScale;

    return LayoutBuilder(
      builder: (context, constraints) {
        // 用实际可用宽度计算列数，横屏左侧 flex=3 时只有 60% 宽度
        final availWidth = constraints.maxWidth;
        final cols = (availWidth / (200 * s)).floor().clamp(2, 4);

        return Padding(
          padding: EdgeInsets.all(14 * s),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('选择菜品（直接点击 + / - 加减）',
                  style: TextStyle(fontSize: 16 * s, fontWeight: FontWeight.bold)),
              SizedBox(height: 10 * s),
              if (_menu.isEmpty)
                Expanded(
                  child: Center(
                    child: Text('暂无菜单，请先在【设置】页添加菜品和价格',
                        style: TextStyle(color: Colors.grey, fontSize: 16 * s)),
                  ),
                )
              else
                Expanded(
                  child: GridView.builder(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: cols,
                      // 让卡片足够高，名称清晰可见
                      childAspectRatio: 0.88,
                      mainAxisSpacing: 10 * s,
                      crossAxisSpacing: 10 * s,
                    ),
                    itemCount: _menu.length,
                    itemBuilder: (context, index) {
                      final m = _menu[index];
                      final qty = _qtyOf(m);
                      return _buildTabletMenuCard(m, qty);
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// 平板菜单卡片 - 大按钮设计（直接点击加减，不弹输入框）
  Widget _buildTabletMenuCard(MenuItem m, int qty) {
    final s = _uiScale;
    final bool hasQty = qty > 0;
    return Card(
      elevation: hasQty ? 4 : 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: hasQty
            ? BorderSide(color: Colors.green.shade400, width: 2)
            : BorderSide.none,
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 10 * s, vertical: 10 * s),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // 菜品名称（大字，居上，最多2行）
            SizedBox(
              height: 56 * s,
              child: Center(
                child: Text(
                  m.name,
                  style: TextStyle(fontSize: 18 * s, fontWeight: FontWeight.bold, height: 1.3),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
              ),
            ),
            // 价格 + 辣度标签
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (m.spicyEnabled)
                  Text('🌶 ', style: TextStyle(fontSize: 13 * s)),
                Text('${fmt(m.price)} $_currency',
                    style: TextStyle(fontSize: 14 * s, color: Colors.grey[700], fontWeight: FontWeight.w500)),
              ],
            ),
            const Spacer(),
            // 加减控制区
            if (hasQty) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 48 * s,
                    height: 48 * s,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.orange[400],
                        padding: EdgeInsets.zero,
                      ),
                      onPressed: () => _decrease(m),
                      child: Icon(Icons.remove, size: 24 * s),
                    ),
                  ),
                  SizedBox(
                    width: 44 * s,
                    child: Text(
                      '$qty',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 24 * s, fontWeight: FontWeight.bold),
                    ),
                  ),
                  SizedBox(
                    width: 48 * s,
                    height: 48 * s,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.green[500],
                        padding: EdgeInsets.zero,
                      ),
                      onPressed: () => _increase(m),
                      child: Icon(Icons.add, size: 24 * s),
                    ),
                  ),
                ],
              ),
            ] else ...[
              SizedBox(
                width: double.infinity,
                height: 48 * s,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.green[400],
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  // 直接加一，不弹输入框
                  onPressed: () => _increase(m),
                  child: Text('+ 添加', style: TextStyle(fontSize: 17 * s, color: Colors.white, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 平板右侧订单面板（横屏）
  Widget _buildTabletOrderPanel(BuildContext context) {
    final s = _uiScale;
    return Padding(
      padding: EdgeInsets.all(16 * s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 0. 用餐方式（堂食 / 打包）+ 堂食桌号（面板最顶端）
          _buildDiningSelector(s),
          SizedBox(height: 10 * s),

          // 1. 总金额
          Container(
            padding: EdgeInsets.all(12 * s),
            decoration: BoxDecoration(
                color: Colors.blueGrey[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blueGrey)),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('总金额', style: TextStyle(fontSize: 20 * s, fontWeight: FontWeight.bold)),
              Text('${fmt(_total)} $_currency',
                  style: TextStyle(fontSize: 26 * s, fontWeight: FontWeight.bold, color: Colors.red)),
            ]),
          ),
          SizedBox(height: 10 * s),

          // 2. 保存并打印小票
          SizedBox(
            height: 56 * s,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green[700],
              ),
              onPressed: _printing ? null : _saveAndPrint,
              child: _printing
                  ? SizedBox(height: 28 * s, width: 28 * s, child: const CircularProgressIndicator(color: Colors.white, strokeWidth: 3))
                  : Text('保存并打印小票', style: TextStyle(fontSize: 20 * s, color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ),
          SizedBox(height: 12 * s),

          // 3. 已选菜品列表
          Text('已选菜品', style: TextStyle(fontSize: 18 * s, fontWeight: FontWeight.bold)),
          SizedBox(height: 6 * s),
          Expanded(
            child: _items.isEmpty
                ? Center(
                    child: Text('暂无已选菜品', style: TextStyle(color: Colors.grey, fontSize: 16 * s)))
                : ListView.builder(
                    itemCount: _items.length,
                    itemBuilder: (context, index) {
                      final item = _items[index];
                      return Card(
                        margin: EdgeInsets.only(bottom: 8 * s),
                        child: ListTile(
                          title: Text(item.name, style: TextStyle(fontSize: 18 * s, fontWeight: FontWeight.w600)),
                          subtitle: Text('${item.quantity} × ${fmt(item.price)} = ${fmt(item.subtotal)} $_currency',
                              style: TextStyle(fontSize: 15 * s)),
                          trailing: SizedBox(
                            width: 52 * s,
                            height: 52 * s,
                            child: FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.red[100],
                                padding: EdgeInsets.zero,
                              ),
                              onPressed: () => _removeItem(index),
                              child: Icon(Icons.delete, size: 26 * s, color: Colors.red),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          SizedBox(height: 8 * s),

          // 4. 备注输入
          TextField(
            controller: _noteCtrl,
            maxLines: 2,
            style: TextStyle(fontSize: 16 * s),
            decoration: const InputDecoration(
              hintText: '备注（选填，如：少辣、不要葱）',
              border: OutlineInputBorder(),
            ),
          ),
          SizedBox(height: 8 * s),

          // 5. 单号显示
          Container(
            padding: EdgeInsets.all(10 * s),
            decoration: BoxDecoration(
              color: Colors.blueGrey[700],
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('本单号', style: TextStyle(fontSize: 18 * s, color: Colors.white, fontWeight: FontWeight.bold)),
                SizedBox(width: 14 * s),
                Text(formatNo(_nextNo),
                    style: TextStyle(
                        fontSize: 28 * s, color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 4)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== 历史订单页面 ====================

class OrderHistoryPage extends StatefulWidget {
  const OrderHistoryPage({super.key});

  @override
  State<OrderHistoryPage> createState() => _OrderHistoryPageState();
}

class _OrderHistoryPageState extends State<OrderHistoryPage> {
  List<Order> _orders = [];
  bool _loading = false;
  String _currency = 'RM';

  @override
  void initState() {
    super.initState();
    _loadOrders();
  }

  Future<void> _loadOrders() async {
    setState(() => _loading = true);
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('orders') ?? [];
    final orders = list.reversed.map((s) => decodeOrder(s)).whereType<Order>().toList();
    final currency = await SettingsStore.getCurrency();
    setState(() {
      _orders = orders;
      _currency = currency;
      _loading = false;
    });
  }

  Future<void> _reprint(Order o) async {
    await SettingsStore.addLog('--- 历史订单重打：单号 ${o.orderNo} ---');
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选择重新打印内容'),
        content: Text('单号 ${o.orderNo} 选择打印格式：'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'cancel'), child: const Text('取消')),
          OutlinedButton(
              onPressed: () => Navigator.pop(ctx, 'kitchen'), child: const Text('补打厨房单')),
          OutlinedButton(
              onPressed: () => Navigator.pop(ctx, 'invoice'), child: const Text('补打发票')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, 'both'), child: const Text('都打印')),
        ],
      ),
    );
    if (choice == null || choice == 'cancel' || !mounted) return;

    try {
      // 未连接时自动重连一次
      if (!await ensureBluetoothConnected()) {
        await SettingsStore.addLog('重打：蓝牙未连接且自动重连失败');
        if (mounted) {
          showDialog(
              context: context,
              builder: (_) => AlertDialog(
                    title: const Text('蓝牙未连接'),
                    content: const Text('自动重连失败，请检查打印机是否已开机、蓝牙是否已配对'),
                    actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('确定'))],
                  ));
        }
        return;
      }
      final settings = await loadReceiptSettings();
      bool okInvoice = true;
      bool okKitchen = true;
      
      if (choice == 'invoice' || choice == 'both') {
        final chunks = buildEscPosBytesChunks(o, settings);
        final r = await sendEscPosBytesChunked(chunks);
        okInvoice = (r == true);
      }
      if (choice == 'kitchen' || choice == 'both') {
        final chunks = buildKitchenEscPosBytesChunks(o, settings);
        final r = await sendEscPosBytesChunked(chunks);
        okKitchen = (r == true);
      }

      if (mounted) {
        if (okInvoice && okKitchen) {
          await SettingsStore.addLog('重打成功');
          _showMsg('重新打印成功！');
        } else {
          await SettingsStore.addLog('重打失败：okInvoice=$okInvoice, okKitchen=$okKitchen');
          _showMsg('打印失败，请检查打印机状态');
        }
      }
    } catch (e) {
      await SettingsStore.addLog('重打异常: $e');
      if (mounted) _showMsg('打印异常: $e');
    }
  }

  void _showMsg(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 导出统计：选择日期范围 → 生成 CSV → 保存到手机"下载"目录
  Future<void> _exportStats() async {
    final now = DateTime.now();
    // 默认本月 1 号到今天
    final defaultStart = DateTime(now.year, now.month, 1);
    final start = await showDatePicker(
      context: context,
      initialDate: defaultStart,
      firstDate: DateTime(2020, 1, 1),
      lastDate: now,
      helpText: '选择开始日期',
    );
    if (start == null || !mounted) return;
    final end = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: start,
      lastDate: now,
      helpText: '选择结束日期',
    );
    if (end == null || !mounted) return;

    // 筛选日期范围内订单（含起止当天）
    final dayStart = DateTime(start.year, start.month, start.day);
    final dayEnd = DateTime(end.year, end.month, end.day, 23, 59, 59);
    final orders = _orders
        .where((o) => !o.time.isBefore(dayStart) && !o.time.isAfter(dayEnd))
        .toList();
    if (orders.isEmpty) {
      if (mounted) _showMsg('所选日期范围内没有订单');
      return;
    }

    final currency = await SettingsStore.getCurrency();
    final csv = _buildStatsCsv(orders, dayStart, dayEnd, currency);
    final name =
        'orders_${formatDate(dayStart)}_${formatDate(dayEnd)}.csv';
    final r = await platform.invokeMethod('saveCsvFile', {'name': name, 'content': csv});
    if (mounted) _showMsg('$r');
  }

  /// 生成统计 CSV：汇总（总单数/销售/菜品排) + 订单明细
  /// 带 UTF-8 BOM，Excel/WPS 可直接打开（中文不乱码）
  String _buildStatsCsv(List<Order> orders, DateTime start, DateTime end, String currency) {
    final sb = StringBuffer();
    sb.write('\uFEFF'); // UTF-8 BOM
    var totalSales = 0.0;
    final dishMap = <String, List<double>>{}; // 菜品名 -> [销量, 销售额]
    for (final o in orders) {
      totalSales += o.total;
      for (final it in o.items) {
        final e = dishMap.putIfAbsent(it.name, () => [0, 0.0]);
        e[0] += it.quantity;
        e[1] += it.subtotal;
      }
    }
    // ===== 汇总区 =====
    sb.writeln('导出时间,${formatTime(DateTime.now())}');
    sb.writeln('统计范围,${formatDate(start)} 至 ${formatDate(end)}');
    sb.writeln('总记单数,${orders.length}');
    sb.writeln('总销售额,$currency${fmt(totalSales)}');
    sb.writeln('平均每单,$currency${fmt(totalSales / orders.length)}');
    sb.writeln('');
    sb.writeln('菜品销量排行');
    sb.writeln('菜品,销量,销售额');
    final ranked = dishMap.entries.toList()
      ..sort((a, b) => b.value[0].compareTo(a.value[0]));
    for (final e in ranked) {
      sb.writeln('${e.key},${e.value[0]},$currency${fmt(e.value[1])}');
    }
    sb.writeln('');
    // ===== 明细区 =====
    sb.writeln('订单明细');
    sb.writeln('单号,时间,菜品明细,总金额,备注');
    for (final o in orders) {
      final items = o.items.map((it) => '${it.name}x${it.quantity}').join(' / ');
      // CSV 转义：含逗号/引号的字段用引号包裹
      final itemsEsc = '"${items.replaceAll('"', '""')}"';
      final note = o.note.replaceAll('"', '""').replaceAll('\n', ' ');
      sb.writeln('${o.orderNo},${formatTime(o.time)},$itemsEsc,$currency${fmt(o.total)},"$note"');
    }
    return sb.toString();
  }

  /// 删除历史订单前需输入授权密码（与解锁密码相同），验证通过才允许删除
  Future<bool> _promptDeletePassword() async {
    var passed = false;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final ctrl = TextEditingController();
        String? error;
        bool checkAndPop() {
          if (ctrl.text.trim() == AuthService.appPassword) {
            passed = true;
            Navigator.pop(ctx);
            return true;
          }
          return false;
        }

        return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('删除历史订单'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('删除后无法恢复，请输入授权密码确认：'),
                const SizedBox(height: 12),
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) {
                    if (!checkAndPop()) {
                      setDialogState(() => error = '密码错误，请重新输入');
                      ctrl.clear();
                    }
                  },
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 20, letterSpacing: 4),
                  decoration: InputDecoration(
                    hintText: '请输入授权密码',
                    errorText: error,
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () {
                  if (!checkAndPop()) {
                    setDialogState(() => error = '密码错误，请重新输入');
                    ctrl.clear();
                  }
                },
                child: const Text('确认删除'),
              ),
            ],
          ),
        );
      },
    );
    return passed;
  }

  Future<void> _delete(int index) async {
    if (!await _promptDeletePassword()) return;
    if (!mounted) return;
    final o = _orders[index];
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('orders') ?? [];
    if (index >= 0 && index < list.length) {
      list.removeAt(list.length - 1 - index);
      await prefs.setStringList('orders', list);
      setState(() => _orders.removeAt(index));
      await SettingsStore.addLog('已删除历史订单：单号 ${o.orderNo}（授权密码验证通过）');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isTablet = isTabletDevice(context);
    return Scaffold(
      appBar: AppBar(
          title: const Text('历史订单'),
          actions: [
            IconButton(
                icon: Icon(Icons.download_outlined, size: isTablet ? 32 : 24),
                tooltip: '导出统计（CSV）',
                onPressed: _exportStats),
            IconButton(icon: Icon(Icons.refresh, size: isTablet ? 32 : 24), onPressed: _loadOrders),
          ]),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _orders.isEmpty
              ? Center(
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.inbox, size: isTablet ? 96 : 72, color: Colors.grey),
                    SizedBox(height: isTablet ? 24 : 16),
                    Text('暂无历史订单', style: TextStyle(color: Colors.grey, fontSize: isTablet ? 22 : 18)),
                  ]))
              : ListView.builder(
                  padding: EdgeInsets.all(isTablet ? 16 : 8),
                  itemCount: _orders.length,
                  itemBuilder: (context, index) {
                    final o = _orders[index];
                    return Card(
                      margin: EdgeInsets.only(bottom: isTablet ? 12 : 8),
                      child: ListTile(
                        contentPadding: EdgeInsets.symmetric(
                            horizontal: isTablet ? 24 : 16,
                            vertical: isTablet ? 16 : 12),
                        title: Text('单号 ${o.orderNo} · ${o.items.length} 道菜',
                            style: TextStyle(fontSize: isTablet ? 22 : 18)),
                        subtitle: Text('${formatTime(o.time)}  合计: ${fmt(o.total)} $_currency',
                            style: TextStyle(fontSize: isTablet ? 18 : 14)),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          // 大按钮：重新打印
                          SizedBox(
                            width: isTablet ? 64 : 48,
                            height: isTablet ? 64 : 48,
                            child: FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.green[100],
                                padding: EdgeInsets.zero,
                              ),
                              onPressed: () => _reprint(o),
                              child: Icon(Icons.replay, color: Colors.green, size: isTablet ? 32 : 28),
                            ),
                          ),
                          const SizedBox(width: 8),
                          // 大按钮：删除
                          SizedBox(
                            width: isTablet ? 64 : 48,
                            height: isTablet ? 64 : 48,
                            child: FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.red[100],
                                padding: EdgeInsets.zero,
                              ),
                              onPressed: () => _delete(index),
                              child: Icon(Icons.delete, color: Colors.red, size: isTablet ? 32 : 28),
                            ),
                          ),
                        ]),
                        onTap: () => _reprint(o),
                      ),
                    );
                  },
                ),
    );
  }
}

// ==================== 备菜页面（勾选历史订单 → 打印厨房单 + 产品数量汇总）====================

/// 备菜页：勾选多张历史单据，一键打印一张产品数量汇总小票，
/// 统计每样产品的数量总计，方便后厨按总量备菜
class PrepPage extends StatefulWidget {
  const PrepPage({super.key, this.refreshSignal});

  /// 切换到本页时由 MainScreen 自增，通知重新加载最新订单
  final ValueNotifier<int>? refreshSignal;

  @override
  State<PrepPage> createState() => _PrepPageState();
}

class _PrepPageState extends State<PrepPage> {
  List<Order> _orders = [];
  final Set<String> _selectedIds = {};
  bool _loading = false;
  bool _printing = false;
  bool _todayOnly = true; // 默认只显示今天日期的菜单
  bool _plainOnlyFilter = false; // 只看无辣单（厨房可以先出）
  String _currency = 'RM';

  @override
  void initState() {
    super.initState();
    widget.refreshSignal?.addListener(_onRefreshSignal);
    _loadOrders();
  }

  @override
  void dispose() {
    widget.refreshSignal?.removeListener(_onRefreshSignal);
    super.dispose();
  }

  void _onRefreshSignal() => _loadOrders();

  Future<void> _loadOrders() async {
    setState(() => _loading = true);
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('orders') ?? [];
    var orders = list.reversed.map((s) => decodeOrder(s)).whereType<Order>().toList();
    // 默认只看今天的菜单，可切换查看全部
    if (_todayOnly) {
      final now = DateTime.now();
      orders = orders
          .where((o) =>
              o.time.year == now.year && o.time.month == now.month && o.time.day == now.day)
          .toList();
    }
    // 只看无辣单：整单没有辣的，厨房不用多一道工序
    if (_plainOnlyFilter) {
      orders = orders.where((o) => o.isPlainOnly).toList();
    }
    final currency = await SettingsStore.getCurrency();
    // 清掉已删除或不在当前列表中订单的勾选
    final ids = orders.map((o) => o.id).toSet();
    _selectedIds.removeWhere((id) => !ids.contains(id));
    if (mounted) {
      setState(() {
        _orders = orders;
        _currency = currency;
        _loading = false;
      });
    }
  }

  bool get _allSelected => _orders.isNotEmpty && _selectedIds.length == _orders.length;

  void _toggleAll() {
    setState(() {
      if (_allSelected) {
        _selectedIds.clear();
      } else {
        _selectedIds.addAll(_orders.map((o) => o.id));
      }
    });
  }

  void _toggleOne(Order o) {
    setState(() {
      if (_selectedIds.contains(o.id)) {
        _selectedIds.remove(o.id);
      } else {
        _selectedIds.add(o.id);
      }
    });
  }

  /// 汇总：品类 → 口味两级（和打印共用 aggregatePrep，保证屏幕与纸上一致）
  List<PrepGroup> _aggregate(List<Order> orders) => aggregatePrep(orders);

  /// 汇总面板里的胶囊文字
  String _summaryLine(PrepGroup g) {
    if (!g.byCategory) return '${g.name} ×${g.total}';
    return '${g.name} 共${g.total}（不辣 ×${g.plainQty} / 辣 ×${g.spicyQty}）';
  }

  /// 打印已勾选订单的备菜汇总小票：每样产品数量总计（不逐单打印）
  Future<void> _printSelected() async {
    final selected = _orders.where((o) => _selectedIds.contains(o.id)).toList()
      ..sort((a, b) => a.time.compareTo(b.time));
    if (selected.isEmpty) {
      _showMsg('请先勾选要打印的订单');
      return;
    }

    setState(() => _printing = true);
    var ok = true;
    try {
      // 未连接时自动重连一次
      if (!await ensureBluetoothConnected()) {
        await SettingsStore.addLog('备菜汇总打印：蓝牙未连接且自动重连失败');
        ok = false;
        if (mounted) {
          showDialog(
            context: context,
            builder: (_) => AlertDialog(
              title: const Text('蓝牙未连接'),
              content: const Text('自动重连失败，请检查打印机是否已开机、蓝牙是否已配对'),
              actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('确定'))],
            ),
          );
        }
        return;
      }
      final settings = await loadReceiptSettings();

      await SettingsStore.addLog('--- 备菜汇总打印（${selected.length} 单）---');
      final chunks = buildPrepSummaryEscPosBytesChunks(selected, settings);
      final r = await sendEscPosBytesChunked(chunks);
      ok = (r == true);

      if (mounted) {
        if (ok) {
          await SettingsStore.addLog('备菜汇总打印成功（${selected.length} 单）');
          // 打印成功后清空所有勾选
          setState(() => _selectedIds.clear());
          _showMsg('备菜汇总打印完成（${selected.length} 单）');
        } else {
          await SettingsStore.addLog('备菜汇总打印失败');
          _showMsg('打印失败，请检查打印机状态');
        }
      }
    } catch (e) {
      await SettingsStore.addLog('备菜汇总打印异常: $e');
      if (mounted) _showMsg('打印异常: $e');
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  void _showMsg(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final isTablet = isTabletDevice(context);
    final selectedOrders = _orders.where((o) => _selectedIds.contains(o.id)).toList();
    final summary = _aggregate(selectedOrders);

    return Scaffold(
      appBar: AppBar(
        title: const Text('备菜'),
        actions: [
          IconButton(
            icon: Icon(_todayOnly ? Icons.today : Icons.calendar_month,
                size: isTablet ? 32 : 24,
                color: _todayOnly ? Theme.of(context).colorScheme.primary : null),
            tooltip: _todayOnly ? '当前：仅今天订单，点击查看全部' : '当前：全部订单，点击仅看今天',
            onPressed: () {
              setState(() => _todayOnly = !_todayOnly);
              _loadOrders();
            },
          ),
          IconButton(
            icon: Icon(_plainOnlyFilter ? Icons.filter_alt : Icons.filter_alt_outlined,
                size: isTablet ? 32 : 24,
                color: _plainOnlyFilter ? Colors.green : null),
            tooltip: _plainOnlyFilter ? '当前：只看无辣单，点击显示全部' : '只看无辣单（可以先出）',
            onPressed: () {
              setState(() => _plainOnlyFilter = !_plainOnlyFilter);
              _loadOrders();
            },
          ),
          IconButton(
            icon: Icon(_allSelected ? Icons.deselect : Icons.select_all, size: isTablet ? 32 : 24),
            tooltip: _allSelected ? '取消全选' : '全选',
            onPressed: _orders.isEmpty ? null : _toggleAll,
          ),
          IconButton(
            icon: Icon(Icons.refresh, size: isTablet ? 32 : 24),
            tooltip: '刷新',
            onPressed: _loadOrders,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _orders.isEmpty
              ? Center(
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.inbox, size: isTablet ? 96 : 72, color: Colors.grey),
                    SizedBox(height: isTablet ? 24 : 16),
                    Text(_todayOnly ? '今天暂无订单' : '暂无历史订单',
                        style: TextStyle(color: Colors.grey, fontSize: isTablet ? 22 : 18)),
                  ]))
              : Column(
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(isTablet ? 20 : 16, isTablet ? 12 : 8, isTablet ? 20 : 16, 0),
                      child: Row(children: [
                        Icon(Icons.touch_app, size: isTablet ? 20 : 16, color: Colors.grey),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text('勾选单据后点打印，自动汇总每样产品数量',
                              style: TextStyle(color: Colors.grey, fontSize: isTablet ? 16 : 12)),
                        ),
                      ]),
                    ),
                    Expanded(child: _buildOrderList(isTablet)),
                    if (selectedOrders.isNotEmpty)
                      _buildSummaryPanel(selectedOrders, summary, isTablet),
                  ],
                ),
    );
  }

  Widget _buildOrderList(bool isTablet) {
    return ListView.builder(
      padding: EdgeInsets.all(isTablet ? 16 : 8),
      itemCount: _orders.length,
      itemBuilder: (context, index) {
        final o = _orders[index];
        final checked = _selectedIds.contains(o.id);
        final itemsText = o.items.map((it) => '${it.name}x${it.quantity}').join('、');
        return Card(
          margin: EdgeInsets.only(bottom: isTablet ? 12 : 8),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _toggleOne(o),
            child: Padding(
              padding: EdgeInsets.symmetric(
                  horizontal: isTablet ? 16 : 8, vertical: isTablet ? 14 : 10),
              child: Row(children: [
                SizedBox(
                  width: isTablet ? 40 : 32,
                  height: isTablet ? 40 : 32,
                  child: Checkbox(value: checked, onChanged: (_) => _toggleOne(o)),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Text('${o.diningPrefix}单号 ${o.orderNo}',
                          style: TextStyle(
                              fontSize: isTablet ? 22 : 17,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(width: 8),
                      // 无辣单标记：整单没辣，厨房不用多一道工序，可以先出
                      Container(
                        padding: EdgeInsets.symmetric(
                            horizontal: isTablet ? 10 : 6, vertical: isTablet ? 3 : 1),
                        decoration: BoxDecoration(
                          color: o.isPlainOnly ? Colors.green[50] : Colors.red[50],
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                              color: o.isPlainOnly ? Colors.green[300]! : Colors.red[300]!),
                        ),
                        child: Text(
                          o.isPlainOnly ? '无辣 · 可先出' : '含辣',
                          style: TextStyle(
                              fontSize: isTablet ? 15 : 11,
                              fontWeight: FontWeight.w600,
                              color: o.isPlainOnly ? Colors.green[800] : Colors.red[800]),
                        ),
                      ),
                      const Spacer(),
                      Text(formatTime(o.time),
                          style: TextStyle(color: Colors.grey, fontSize: isTablet ? 18 : 13)),
                    ]),
                    SizedBox(height: isTablet ? 6 : 4),
                    Text(
                      itemsText,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: isTablet ? 18 : 13, color: Colors.blueGrey),
                    ),
                  ]),
                ),
              ]),
            ),
          ),
        );
      },
    );
  }

  /// 底部汇总面板：已选单数/总份数 + 每样产品数量总计（按数量降序） + 打印按钮
  Widget _buildSummaryPanel(
      List<Order> selectedOrders, List<PrepGroup> summary, bool isTablet) {
    final totalPieces = summary.fold<int>(0, (s, g) => s + g.total);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.grey[100],
        border: const Border(top: BorderSide(color: Colors.black12)),
      ),
      padding: EdgeInsets.fromLTRB(
          isTablet ? 20 : 14, isTablet ? 14 : 10, isTablet ? 20 : 14, isTablet ? 12 : 8),
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.restaurant_menu, size: isTablet ? 22 : 18, color: Colors.deepOrange),
            const SizedBox(width: 6),
            Expanded(
              child: Text('备菜汇总：${selectedOrders.length} 单 · 共 $totalPieces 份 ($_currency${fmt(selectedOrders.fold<double>(0, (s, o) => s + o.total))})',
                  style: TextStyle(fontSize: isTablet ? 20 : 15, fontWeight: FontWeight.bold)),
            ),
          ]),
          SizedBox(height: isTablet ? 10 : 8),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: isTablet ? 180 : 130),
            child: SingleChildScrollView(
              child: Wrap(
                spacing: isTablet ? 10 : 8,
                runSpacing: isTablet ? 10 : 8,
                children: [
                  for (final g in summary)
                    Container(
                      padding: EdgeInsets.symmetric(
                          horizontal: isTablet ? 14 : 10, vertical: isTablet ? 8 : 5),
                      decoration: BoxDecoration(
                        color: Colors.deepOrange[50],
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: Colors.deepOrange[200]!),
                      ),
                      child: Text(
                        _summaryLine(g),
                        style: TextStyle(
                            fontSize: isTablet ? 19 : 14,
                            color: Colors.deepOrange[900],
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                ],
              ),
            ),
          ),
          SizedBox(height: isTablet ? 12 : 10),
          SizedBox(
            width: double.infinity,
            height: isTablet ? 64 : 52,
            child: FilledButton.icon(
              onPressed: _printing ? null : _printSelected,
              icon: _printing
                  ? SizedBox(
                      width: isTablet ? 26 : 20,
                      height: isTablet ? 26 : 20,
                      child: const CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Icon(Icons.print, size: isTablet ? 30 : 24),
              label: Text(
                _printing ? '打印中…' : '打印备菜汇总（${selectedOrders.length} 单）',
                style: TextStyle(fontSize: isTablet ? 22 : 17, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

// ==================== 设置页面（菜单管理 + 外卖单号）====================

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  List<MenuItem> _menu = [];
  final _nameCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _storeNameCtrl = TextEditingController(); // 店铺名称（小票标题）
  final _subtitle1Ctrl = TextEditingController(); // 副标题 1（店名下方）
  final _subtitle2Ctrl = TextEditingController(); // 副标题 2（店名下方）
  final _footerCtrl = TextEditingController(); // 底部提示语
  final _currencyCtrl = TextEditingController(); // 货币符号
  final _phoneCtrl = TextEditingController(); // 手机号
  // 小票标签文字（可自定义）
  final _timeLabelCtrl = TextEditingController();
  final _dishLabelCtrl = TextEditingController();
  final _qtyLabelCtrl = TextEditingController();
  final _priceLabelCtrl = TextEditingController();
  final _subtotalLabelCtrl = TextEditingController();
  final _totalLabelCtrl = TextEditingController();
  final _startNoCtrl = TextEditingController();
  int _nextNo = 1;
  int _titleFont = 3; // 标题字号（默认 2x2）
  int _orderNoFont = 3; // 底部单号字号（默认 2x2）
  int _bodyFont = 0; // 正文字号（默认 1x1）
  String _paperWidth = '80mm'; // 打印纸张规格：'50mm' 或 '80mm'
  bool _tabletMode = false; // 平板模式开关
  List<String> _logs = []; // 打印调试日志
  String _qrBase64 = ''; // 付款二维码 base64 PNG
  String _logoBase64 = ''; // 招牌图片 base64 PNG
  bool _logoPrintEnabled = true; // 是否打印招牌图片
  int _logoPrintSize = 1; // 招牌图片打印大小：0=小 1=中 2=大
  bool _showName = true; // 是否在小票显示店铺名称
  bool _showSubtitle = true; // 是否在小票显示副标题（与店名独立）
  int _qrPrintSize = 0; // 二维码打印大小：0=自动 160=小 240=中 320=大
  int _remainingDays = 30; // 授权剩余天数
  List<TagDef> _tags = []; // 标签库（品类 + 口味）
  List<String> _tableNos = []; // 桌号列表（堂食点单时下拉选择）
  String _addCatTag = ''; // 新增菜品时选中的品类标签
  String _addFlavorTag = ''; // 新增菜品时选中的口味标签

  String get _currency => _currencyCtrl.text.trim().isEmpty ? 'RM' : _currencyCtrl.text.trim();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final menu = await SettingsStore.loadMenu();
    final tags = await SettingsStore.loadTags();
    final tableNos = await SettingsStore.getTableNos();
    final next = await SettingsStore.getCurrentNo();
    final start = await SettingsStore.getStartNo();
    final days = await AuthService.getRemainingDays();
    _storeNameCtrl.text = await SettingsStore.getStoreName();
    _subtitle1Ctrl.text = await SettingsStore.getSubtitle1();
    _subtitle2Ctrl.text = await SettingsStore.getSubtitle2();
    _footerCtrl.text = await SettingsStore.getFooterText();
    _currencyCtrl.text = await SettingsStore.getCurrency();
    _phoneCtrl.text = await SettingsStore.getPhone();
    _timeLabelCtrl.text = await SettingsStore.getTimeLabel();
    _dishLabelCtrl.text = await SettingsStore.getDishLabel();
    _qtyLabelCtrl.text = await SettingsStore.getQtyLabel();
    _priceLabelCtrl.text = await SettingsStore.getPriceLabel();
    _subtotalLabelCtrl.text = await SettingsStore.getSubtotalLabel();
    _totalLabelCtrl.text = await SettingsStore.getTotalLabel();
    _titleFont = await SettingsStore.getTitleFont();
    _orderNoFont = await SettingsStore.getOrderNoFont();
    _bodyFont = await SettingsStore.getBodyFont();
    _paperWidth = await SettingsStore.getPaperWidth();
    _tabletMode = await SettingsStore.getTabletMode();
    _logs = await SettingsStore.loadLogs();
    _qrBase64 = await SettingsStore.getPaymentQr();
    final logoBase64 = await SettingsStore.getLogoBase64();
    final logoPrintEnabled = await SettingsStore.getLogoPrintEnabled();
    final logoPrintSize = await SettingsStore.getLogoPrintSize();
    final showName = await SettingsStore.getShowName();
    final showSubtitle = await SettingsStore.getShowSubtitle();
    final qrPrintSize = await SettingsStore.getQrPrintSize();
    if (mounted) {
      setState(() {
        _menu = menu;
        _tags = tags;
        _tableNos = tableNos;
        _nextNo = next;
        _startNoCtrl.text = '$start';
        _remainingDays = days;
        _logoBase64 = logoBase64;
        _logoPrintEnabled = logoPrintEnabled;
        _logoPrintSize = logoPrintSize;
        _showName = showName;
        _showSubtitle = showSubtitle;
        _qrPrintSize = qrPrintSize;
      });
    }
  }

  Future<void> _addMenu() async {
    final name = _nameCtrl.text.trim();
    final price = double.tryParse(_priceCtrl.text.trim());
    if (name.isEmpty || price == null || price < 0) {
      if (mounted) _showMsg('请输入菜品名称和正确的单价');
      return;
    }
    setState(() {
      _menu.add(MenuItem(
        name: name,
        price: price,
        catTag: _addCatTag,
        flavorTag: _addFlavorTag,
      ));
      _addCatTag = '';
      _addFlavorTag = '';
    });
    _nameCtrl.clear();
    _priceCtrl.clear();
    await SettingsStore.saveMenu(_menu);
    if (mounted) _showMsg('已添加：$name ${fmt(price)} 元');
  }

  /// 编辑/删除菜单项
  Future<void> _editMenu(int idx) async {
    final m = _menu[idx];
    final nCtrl = TextEditingController(text: m.name);
    final pCtrl = TextEditingController(text: '${m.price}');
    var editCat = m.catTag;
    var editFlavor = m.flavorTag;
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('编辑菜单'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                    controller: nCtrl,
                    style: const TextStyle(fontSize: 18),
                    decoration: const InputDecoration(labelText: '菜品名称')),
                const SizedBox(height: 8),
                TextField(
                    controller: pCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    style: const TextStyle(fontSize: 18),
                    decoration: InputDecoration(labelText: '单价（$_currency）')),
                const SizedBox(height: 8),
                _tagPickerTile(
                  label: '品类标签（用于合并统计）',
                  value: editCat,
                  type: 'cat',
                  onPicked: (v) {
                    if (ctx.mounted) setDialogState(() => editCat = v);
                  },
                ),
                _tagPickerTile(
                  label: '口味标签（用于区分辣/不辣）',
                  value: editFlavor,
                  type: 'flavor',
                  onPicked: (v) {
                    if (ctx.mounted) setDialogState(() => editFlavor = v);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, 'delete'),
                child: const Text('删除', style: TextStyle(color: Colors.red))),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('保存')),
          ],
        ),
      ),
    );
    if (action == 'delete') {
      setState(() => _menu.removeAt(idx));
      await SettingsStore.saveMenu(_menu);
      if (mounted) _showMsg('已删除');
    } else if (action == 'save') {
      final name = nCtrl.text.trim();
      final price = double.tryParse(pCtrl.text.trim());
      if (name.isEmpty || price == null || price < 0) {
        if (mounted) _showMsg('名称或价格不正确');
        return;
      }
      setState(() => _menu[idx] = MenuItem(
            name: name,
            price: price,
            spicyEnabled: m.spicyEnabled,
            catTag: editCat,
            flavorTag: editFlavor,
          ));
      await SettingsStore.saveMenu(_menu);
      if (mounted) _showMsg('已保存');
    }
  }

  // ==================== 标签管理（品类 / 口味）====================

  /// 新建 / 编辑一个标签；返回保存后的标签（取消返回 null）
  Future<TagDef?> _tagEditor({TagDef? origin, String defaultType = 'cat'}) async {
    final nCtrl = TextEditingController(text: origin?.name ?? '');
    var type = origin?.type ?? defaultType;
    var isSpicy = origin?.isSpicy ?? false;
    bool dup() {
      final n = nCtrl.text.trim();
      return n.isNotEmpty &&
          _tags.any((t) => t.name == n && t.name != (origin?.name ?? ''));
    }

    final result = await showDialog<TagDef>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: Text(origin == null ? '新增标签' : '编辑标签'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nCtrl,
                  autofocus: true,
                  style: const TextStyle(fontSize: 18),
                  decoration:
                      const InputDecoration(labelText: '标签名称（如 鸡架 / 原味 / 辣味）'),
                  onChanged: (_) => setDlg(() {}),
                ),
                const SizedBox(height: 14),
                const Text('类型', style: TextStyle(fontSize: 14, color: Colors.grey)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('品类'),
                      selected: type == 'cat',
                      onSelected: (_) => setDlg(() => type = 'cat'),
                    ),
                    ChoiceChip(
                      label: const Text('口味'),
                      selected: type == 'flavor',
                      onSelected: (_) => setDlg(() => type = 'flavor'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  type == 'cat'
                      ? '品类：把多个菜品合并成同一款产品统计（例如"鸡架"）'
                      : '口味：在品类内部再细分（例如"原味""辣味"）',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                if (type == 'flavor')
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('这个口味带辣（厨房要多一道工序）',
                        style: TextStyle(fontSize: 15)),
                    value: isSpicy,
                    onChanged: (v) => setDlg(() => isSpicy = v ?? false),
                  ),
                if (dup())
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text('已有同名标签',
                        style: TextStyle(fontSize: 13, color: Colors.red)),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                final name = nCtrl.text.trim();
                if (name.isEmpty || dup()) return;
                Navigator.pop(
                    ctx,
                    TagDef(
                      name: name,
                      type: type,
                      isSpicy: type == 'flavor' ? isSpicy : false,
                    ));
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );

    if (result == null) return null;

    setState(() {
      if (origin == null) {
        _tags.add(result);
      } else {
        final idx = _tags.indexOf(origin);
        if (idx >= 0) _tags[idx] = result;
        // 标签改名时同步更新菜单，避免菜单指向一个不存在的标签
        if (origin.name != result.name) _renameTagOnMenu(origin.name, result.name);
      }
    });
    await SettingsStore.saveTags(_tags);
    if (origin != null && origin.name != result.name) {
      await SettingsStore.saveMenu(_menu);
    }
    if (mounted) _showMsg(origin == null ? '已新增标签：${result.name}' : '标签已保存');
    return result;
  }

  /// 标签改名后，把菜单上引用旧名字的地方换成新名字
  void _renameTagOnMenu(String oldName, String newName) {
    for (var i = 0; i < _menu.length; i++) {
      final m = _menu[i];
      final newCat = m.catTag == oldName ? newName : m.catTag;
      final newFlavor = m.flavorTag == oldName ? newName : m.flavorTag;
      if (newCat != m.catTag || newFlavor != m.flavorTag) {
        _menu[i] = MenuItem(
          name: m.name,
          price: m.price,
          spicyEnabled: m.spicyEnabled,
          catTag: newCat,
          flavorTag: newFlavor,
        );
      }
    }
  }

  /// 删除标签；引用它的菜品会自动清空这个标签
  Future<void> _deleteTag(TagDef t) async {
    final usedCount =
        _menu.where((m) => m.catTag == t.name || m.flavorTag == t.name).length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除标签「${t.name}」'),
        content: Text(usedCount > 0
            ? '有 $usedCount 个菜品正在用这个标签，删除后它们的这个标签会被清空。'
            : '确定删除这个标签吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() {
      _tags.remove(t);
      for (var i = 0; i < _menu.length; i++) {
        final m = _menu[i];
        if (m.catTag == t.name || m.flavorTag == t.name) {
          _menu[i] = MenuItem(
            name: m.name,
            price: m.price,
            spicyEnabled: m.spicyEnabled,
            catTag: m.catTag == t.name ? '' : m.catTag,
            flavorTag: m.flavorTag == t.name ? '' : m.flavorTag,
          );
        }
      }
    });
    await SettingsStore.saveTags(_tags);
    await SettingsStore.saveMenu(_menu);
    if (mounted) _showMsg('已删除标签：${t.name}');
  }

  // ==================== 桌号管理（堂食点单时下拉选择）====================

  /// 新增 / 修改桌号；origin=null 表示新增，否则为原桌号（改名）
  Future<void> _tableNoEditor({String? origin}) async {
    final ctrl = TextEditingController(text: origin ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(origin == null ? '新增桌号' : '修改桌号'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(fontSize: 18),
          decoration: const InputDecoration(labelText: '桌号', hintText: '如 65 或 A1'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('保存')),
        ],
      ),
    );
    if (name == null) return;
    if (name.isEmpty) {
      if (mounted) _showMsg('桌号不能为空');
      return;
    }
    // 重名检查（改名时排除自己）
    if (_tableNos.any((t) => t == name && t != origin)) {
      if (mounted) _showMsg('桌号「$name」已存在');
      return;
    }
    if (origin != null && name == origin) return; // 没改
    setState(() {
      if (origin == null) {
        _tableNos.add(name);
      } else {
        final idx = _tableNos.indexOf(origin);
        if (idx >= 0) _tableNos[idx] = name;
      }
    });
    await SettingsStore.setTableNos(_tableNos);
    if (mounted) _showMsg(origin == null ? '已新增桌号：$name' : '桌号已改为：$name');
  }

  /// 删除桌号
  Future<void> _deleteTableNo(String t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除桌号「$t」'),
        content: const Text('删除后新建订单的桌号下拉框里不再显示（不影响已下订单）。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _tableNos.remove(t));
    await SettingsStore.setTableNos(_tableNos);
    if (mounted) _showMsg('已删除桌号：$t');
  }

  /// 选择标签；返回 null=取消，''=不设置，其它=选中的标签名
  Future<String?> _pickTag(String current, String type) async {
    while (true) {
      final names = type == 'cat'
          ? SettingsStore.catTagNames(_tags)
          : SettingsStore.flavorTagNames(_tags);
      final picked = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: Text(type == 'cat' ? '选择品类标签' : '选择口味标签'),
          children: [
            if (names.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 4, 24, 12),
                child: Text('还没有标签，先新建一个',
                    style: TextStyle(fontSize: 14, color: Colors.grey)),
              ),
            for (final name in names)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, name),
                child: Row(
                  children: [
                    SizedBox(
                      width: 22,
                      child: name == current
                          ? const Icon(Icons.check, size: 18, color: Colors.green)
                          : null,
                    ),
                    Text(name, style: const TextStyle(fontSize: 16)),
                    if (type == 'flavor' && SettingsStore.isSpicyFlavor(_tags, name))
                      const Padding(
                        padding: EdgeInsets.only(left: 6),
                        child: Text('🌶', style: TextStyle(fontSize: 14)),
                      ),
                  ],
                ),
              ),
            const Divider(height: 8),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, '__new__'),
              child: Text('+ 新建${type == 'cat' ? '品类' : '口味'}标签',
                  style: const TextStyle(fontSize: 16, color: Colors.blue)),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, ''),
              child: const Text('不设置', style: TextStyle(fontSize: 16, color: Colors.grey)),
            ),
          ],
        ),
      );
      if (picked == null) return null;
      if (picked != '__new__') return picked;
      final nt = await _tagEditor(defaultType: type);
      if (nt != null) return nt.name;
      // 取消新建 → 回到选择列表
    }
  }

  /// 菜单列表副标题的标签文字，如 "  ·  鸡架 / 辣味 🌶"
  String _menuTagLabel(MenuItem m) {
    final parts = <String>[];
    if (m.catTag.isNotEmpty) parts.add(m.catTag);
    if (m.flavorTag.isNotEmpty) {
      parts.add(SettingsStore.isSpicyFlavor(_tags, m.flavorTag)
          ? '${m.flavorTag} 🌶'
          : m.flavorTag);
    }
    if (parts.isEmpty) return '';
    return '  ·  ${parts.join(' / ')}';
  }

  /// 一行"点击选择标签"的控件（菜单表单里用）
  Widget _tagPickerTile({
    required String label,
    required String value,
    required String type,
    required ValueChanged<String> onPicked,
  }) {
    final spicy = type == 'flavor' && SettingsStore.isSpicyFlavor(_tags, value);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(label, style: const TextStyle(fontSize: 13, color: Colors.grey)),
      subtitle: Text(
        value.isEmpty ? '未设置（点击选择）' : (spicy ? '$value 🌶' : value),
        style: TextStyle(
          fontSize: 16,
          color: value.isEmpty ? Colors.grey : Colors.black87,
          fontWeight: value.isEmpty ? FontWeight.normal : FontWeight.w600,
        ),
      ),
      trailing: const Icon(Icons.arrow_drop_down),
      onTap: () async {
        final v = await _pickTag(value, type);
        if (v != null) onPicked(v);
      },
    );
  }

  /// 刷新打印调试日志
  Future<void> _refreshLogs() async {
    final logs = await SettingsStore.loadLogs();
    if (mounted) setState(() => _logs = logs);
  }

  /// 清空打印调试日志
  Future<void> _clearLogs() async {
    await SettingsStore.clearLogs();
    if (mounted) setState(() => _logs = []);
  }

  /// 保存店铺名称（小票标题）
  Future<void> _saveStoreName() async {
    final name = _storeNameCtrl.text.trim();
    if (name.isEmpty) {
      if (mounted) _showMsg('店铺名称不能为空');
      return;
    }
    await SettingsStore.setStoreName(name);
    if (mounted) _showMsg('店铺名称已保存');
  }

  /// 保存副标题两行（店名下方，留空不打印）
  Future<void> _saveSubtitles() async {
    await SettingsStore.setSubtitle1(_subtitle1Ctrl.text.trim());
    await SettingsStore.setSubtitle2(_subtitle2Ctrl.text.trim());
    if (mounted) _showMsg('副标题已保存');
  }

  /// 保存底部提示语
  Future<void> _saveFooterText() async {
    await SettingsStore.setFooterText(_footerCtrl.text.trim());
    if (mounted) _showMsg('底部提示语已保存');
  }

  /// 保存货币符号
  Future<void> _saveCurrency() async {
    final v = _currencyCtrl.text.trim();
    if (v.isEmpty) {
      if (mounted) _showMsg('货币符号不能为空');
      return;
    }
    await SettingsStore.setCurrency(v);
    if (mounted) _showMsg('货币符号已保存（当前：$v）');
  }

  /// 保存手机号
  Future<void> _savePhone() async {
    await SettingsStore.setPhone(_phoneCtrl.text.trim());
    if (mounted) _showMsg('手机号已保存');
  }

  /// 从相册选取付款二维码图片
  Future<void> _pickQrImage() async {
    final picker = ImagePicker();
    final XFile? file = await picker.pickImage(source: ImageSource.gallery);
    if (file == null || !mounted) return;
    try {
      final bytes = await file.readAsBytes();
      // 压缩到 512px 宽以内（保持清晰度同时减小 base64 体积）
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        if (mounted) _showMsg('无法识别图片，请选择 PNG/JPG 格式');
        return;
      }
      final scaled = img.copyResize(decoded, width: 512, interpolation: img.Interpolation.nearest);
      final compressed = img.encodePng(scaled);
      final base64 = 'data:image/png;base64,${base64Encode(compressed)}';
      await SettingsStore.setPaymentQr(base64);
      if (mounted) {
        setState(() => _qrBase64 = base64);
        _showMsg('付款二维码已更新');
      }
    } catch (e) {
      if (mounted) _showMsg('选择图片失败：$e');
    }
  }

  /// 清除已上传的二维码
  Future<void> _clearQr() async {
    await SettingsStore.setPaymentQr('');
    if (mounted) {
      setState(() => _qrBase64 = '');
      _showMsg('二维码已清除');
    }
  }

  /// 从相册选取招牌图片
  Future<void> _pickLogoImage() async {
    final picker = ImagePicker();
    final XFile? file = await picker.pickImage(source: ImageSource.gallery);
    if (file == null || !mounted) return;
    try {
      final bytes = await file.readAsBytes();
      // 压缩到 512px 宽以内（保持体积）
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        if (mounted) _showMsg('无法识别图片，请选择 PNG/JPG 格式');
        return;
      }
      final scaled = img.copyResize(decoded, width: 512, interpolation: img.Interpolation.nearest);
      final compressed = img.encodePng(scaled);
      final base64 = 'data:image/png;base64,${base64Encode(compressed)}';
      await SettingsStore.setLogoBase64(base64);
      if (mounted) {
        setState(() => _logoBase64 = base64);
        _showMsg('招牌图片已更新');
      }
    } catch (e) {
      if (mounted) _showMsg('选择图片失败：$e');
    }
  }

  /// 清除已上传的招牌图片
  Future<void> _clearLogo() async {
    await SettingsStore.setLogoBase64('');
    if (mounted) {
      setState(() => _logoBase64 = '');
      _showMsg('招牌图片已清除');
    }
  }

  /// 切换平板模式
  Future<void> _toggleTabletMode(bool? value) async {
    if (value == null) return;
    await SettingsStore.setTabletMode(value);
    if (mounted) {
      setState(() => _tabletMode = value);
      _showMsg(value ? '已启用平板模式（大按钮+网格菜单）' : '已关闭平板模式');
    }
  }

  /// 字号下拉选择行（four=true 显示 1x1/1x2/2x1/2x2，false 只显示 1x1/1x2）
  Widget _fontRow(String label, int value, Future<void> Function(int?) onChanged, {bool four = true}) {
    const names = ['1x1 正常', '1x2 加高', '2x1 加宽', '2x2 大号'];
    final items = four ? const [0, 1, 2, 3] : const [0, 1];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 16)),
          DropdownButton<int>(
            value: value,
            items: items
                .map((i) => DropdownMenuItem(value: i, child: Text(names[i])))
                .toList(),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  /// 保存小票标签文字（留空则恢复默认）
  Future<void> _saveLabels() async {
    await SettingsStore.setTimeLabel(_timeLabelCtrl.text.trim());
    await SettingsStore.setDishLabel(_dishLabelCtrl.text.trim());
    await SettingsStore.setQtyLabel(_qtyLabelCtrl.text.trim());
    await SettingsStore.setPriceLabel(_priceLabelCtrl.text.trim());
    await SettingsStore.setSubtotalLabel(_subtotalLabelCtrl.text.trim());
    await SettingsStore.setTotalLabel(_totalLabelCtrl.text.trim());
    if (mounted) _showMsg('标签文字已保存');
  }

  /// 标签输入行（左侧灰色默认名，右侧输入框）
  Widget _labelRow(TextEditingController ctrl, String def) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
              width: 76,
              child: Text(def,
                  style: const TextStyle(fontSize: 14, color: Colors.grey))),
          Expanded(
            child: TextField(
              controller: ctrl,
              style: const TextStyle(fontSize: 15),
              decoration: const InputDecoration(isDense: true, hintText: '留空恢复默认'),
            ),
          ),
        ],
      ),
    );
  }

  /// 保存起始数字并重置计数器
  Future<void> _saveStartNo() async {
    final v = int.tryParse(_startNoCtrl.text.trim());
    if (v == null || v < 1) {
      if (mounted) _showMsg('请输入有效的起始数字（≥1）');
      return;
    }
    await SettingsStore.setStartNo(v);
    if (mounted) {
      setState(() => _nextNo = v);
      _showMsg('已设置，下一单从 ${formatNo(v)} 开始');
    }
  }

  void _showMsg(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ===== 软件安全与授权 =====
            const Text('软件授权与安全', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.verified_user_outlined, color: Colors.green, size: 24),
                        const SizedBox(width: 8),
                        const Text('授权状态：正常激活',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.green[50],
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.green.shade300),
                          ),
                          child: Text(
                            '剩余 $_remainingDays 天',
                            style: TextStyle(color: Colors.green[800], fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      '软件采用 30 天周期安全验证，首次及到期时需输入授权密码方可继续使用。',
                      style: TextStyle(fontSize: 13, color: Colors.grey, height: 1.4),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.blueGrey[800],
                        minimumSize: const Size(double.infinity, 42),
                      ),
                      onPressed: () async {
                        final confirm = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('锁定软件'),
                            content: const Text('锁定后将立即弹出密码输入界面，需要重新输入授权密码才能进入。确定锁定吗？'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey, foregroundColor: Colors.white),
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text('确定锁定'),
                              ),
                            ],
                          ),
                        );
                        if (confirm == true) {
                          await AuthService.resetAuth();
                          if (mounted) {
                            Navigator.of(context).pushAndRemoveUntil(
                              MaterialPageRoute(builder: (_) => const AuthGate()),
                              (route) => false,
                            );
                          }
                        }
                      },
                      icon: const Icon(Icons.lock_reset, size: 20),
                      label: const Text('立即锁屏并测试密码'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // ===== 打印机纸张规格 =====
            const Text('打印机纸张规格', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('纸张宽度', style: TextStyle(fontSize: 16)),
                    DropdownButton<String>(
                      value: _paperWidth,
                      items: const [
                        DropdownMenuItem(value: '50mm', child: Text('50mm 便携小票 (32字符/384点)')),
                        DropdownMenuItem(value: '80mm', child: Text('80mm 精臣B3/标准小票 (48字符/576点)')),
                      ],
                      onChanged: (v) async {
                        if (v != null) {
                          await SettingsStore.setPaperWidth(v);
                          setState(() => _paperWidth = v);
                          if (mounted) _showMsg('已切换为 $v 打印格式');
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // ===== 平板模式设置 =====
            const Text('界面显示', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('平板模式', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                        SizedBox(height: 4),
                        Text('启用大按钮、网格菜单布局，支持横竖屏',
                            style: TextStyle(fontSize: 13, color: Colors.grey)),
                      ],
                    ),
                    Switch(
                      value: _tabletMode,
                      onChanged: _toggleTabletMode,
                      activeColor: Colors.blueGrey[700],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // ===== 店铺名称设置 =====
            const Text('店铺名称', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _storeNameCtrl,
                        style: const TextStyle(fontSize: 18),
                        decoration: const InputDecoration(
                            labelText: '店铺名称', hintText: '显示在小票顶部，如：美味小馆'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(onPressed: _saveStoreName, child: const Text('保存')),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            // 勾选隐藏店铺名称（发票和厨房单均不显示店名）
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('在小票上显示店铺名称', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                        SizedBox(height: 4),
                        Text('关闭后发票与厨房单均不打印店名',
                            style: TextStyle(fontSize: 13, color: Colors.grey)),
                      ],
                    ),
                    Switch(
                      value: _showName,
                      onChanged: (v) async {
                        await SettingsStore.setShowName(v);
                        if (mounted) setState(() => _showName = v);
                        _showMsg(v ? '已显示店铺名称' : '已隐藏店铺名称');
                      },
                      activeColor: Colors.blueGrey[700],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            // 勾选隐藏副标题（与店名独立，关闭店名不影响副标题）
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('在小票上显示副标题', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                        SizedBox(height: 4),
                        Text('关闭后发票与厨房单均不打印副标题 1 & 2',
                            style: TextStyle(fontSize: 13, color: Colors.grey)),
                      ],
                    ),
                    Switch(
                      value: _showSubtitle,
                      onChanged: (v) async {
                        await SettingsStore.setShowSubtitle(v);
                        if (mounted) setState(() => _showSubtitle = v);
                        _showMsg(v ? '已显示副标题' : '已隐藏副标题');
                      },
                      activeColor: Colors.blueGrey[700],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text('小票样式', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 副标题 1（店名下方）
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _subtitle1Ctrl,
                            style: const TextStyle(fontSize: 16),
                            decoration: const InputDecoration(
                                labelText: '副标题 1（店名下方）', hintText: '如：营业时间 10:00-22:00，留空不打印'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(onPressed: _saveSubtitles, child: const Text('保存')),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // 副标题 2（店名下方）
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _subtitle2Ctrl,
                            style: const TextStyle(fontSize: 16),
                            decoration: const InputDecoration(
                                labelText: '副标题 2（店名下方）', hintText: '如：美味好吃 欢迎品尝，留空不打印'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(onPressed: _saveSubtitles, child: const Text('保存')),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // 底部提示语
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _footerCtrl,
                            style: const TextStyle(fontSize: 16),
                            decoration: const InputDecoration(
                                labelText: '底部提示语', hintText: '谢谢惠顾，欢迎再次光临！'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(onPressed: _saveFooterText, child: const Text('保存')),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // 货币符号
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _currencyCtrl,
                            style: const TextStyle(fontSize: 16),
                            decoration: const InputDecoration(
                                labelText: '货币符号', hintText: 'RM（马币）'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(onPressed: _saveCurrency, child: const Text('保存')),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // 手机号
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _phoneCtrl,
                            keyboardType: TextInputType.phone,
                            style: const TextStyle(fontSize: 16),
                            decoration: const InputDecoration(
                                labelText: '手机号（打印在小票底部）', hintText: '如 0123456789，留空不打印'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(onPressed: _savePhone, child: const Text('保存')),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // 招牌图片设置
                    const Text('招牌图片（打印在小票顶部）',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('打印小票时显示招牌图片', style: TextStyle(fontSize: 14)),
                      value: _logoPrintEnabled,
                      onChanged: (v) async {
                        if (v != null) {
                          await SettingsStore.setLogoPrintEnabled(v);
                          setState(() => _logoPrintEnabled = v);
                          _showMsg(v ? '已启用招牌图片打印' : '已禁用招牌图片打印');
                        }
                      },
                    ),
                    if (_logoPrintEnabled) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('招牌打印大小', style: TextStyle(fontSize: 14)),
                            DropdownButton<int>(
                              value: _logoPrintSize,
                              items: const [
                                DropdownMenuItem(value: 0, child: Text('小')),
                                DropdownMenuItem(value: 1, child: Text('中')),
                                DropdownMenuItem(value: 2, child: Text('大')),
                              ],
                              onChanged: (v) async {
                                if (v != null) {
                                  await SettingsStore.setLogoPrintSize(v);
                                  setState(() => _logoPrintSize = v);
                                  _showMsg('招牌打印大小已更新');
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                      if (_logoBase64.isNotEmpty)
                        Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.blueGrey.shade300),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Image.memory(
                                base64Decode(_logoBase64.split(',').skip(1).join(',')),
                                height: 100,
                                fit: BoxFit.contain,
                              ),
                            ),
                            Positioned(
                              top: -4,
                              right: -4,
                              child: IconButton(
                                icon: const CircleAvatar(
                                  radius: 12,
                                  backgroundColor: Colors.red,
                                  child: Icon(Icons.close, size: 14, color: Colors.white),
                                ),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                onPressed: _clearLogo,
                                tooltip: '清除招牌图片',
                              ),
                            ),
                          ],
                        )
                      else
                        OutlinedButton.icon(
                          onPressed: _pickLogoImage,
                          icon: const Icon(Icons.image_outlined),
                          label: const Text('上传招牌图片'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(48),
                            textStyle: const TextStyle(fontSize: 14),
                          ),
                        ),
                      const SizedBox(height: 12),
                    ],
                    // 付款二维码（上传后打印在单号下方，含"QR Payment"标签）
                    const Text('付款二维码',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    if (_qrBase64.isNotEmpty)
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.blueGrey.shade300),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Image.memory(
                              base64Decode(_qrBase64.split(',').skip(1).join(',')),
                              height: 120,
                              fit: BoxFit.contain,
                            ),
                          ),
                          Positioned(
                            top: -4,
                            right: -4,
                            child: IconButton(
                              icon: const CircleAvatar(
                                radius: 12,
                                backgroundColor: Colors.red,
                                child: Icon(Icons.close, size: 14, color: Colors.white),
                              ),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              onPressed: _clearQr,
                              tooltip: '清除二维码',
                            ),
                          ),
                        ],
                      )
                    else
                      OutlinedButton.icon(
                        onPressed: _pickQrImage,
                        icon: const Icon(Icons.qr_code_2),
                        label: const Text('上传付款二维码（打印时显示在单号下方）'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                          textStyle: const TextStyle(fontSize: 14),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('二维码打印大小', style: TextStyle(fontSize: 14)),
                          DropdownButton<int>(
                            value: _qrPrintSize,
                            items: const [
                              DropdownMenuItem(value: 0, child: Text('自动（中）')),
                              DropdownMenuItem(value: 160, child: Text('小')),
                              DropdownMenuItem(value: 240, child: Text('中')),
                              DropdownMenuItem(value: 320, child: Text('大')),
                            ],
                            onChanged: (v) async {
                              if (v != null) {
                                await SettingsStore.setQrPrintSize(v);
                                if (mounted) setState(() => _qrPrintSize = v);
                                _showMsg('二维码打印大小已更新');
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    // 字号设置
                    _fontRow('标题字号', _titleFont, (v) async {
                      if (v == null) return;
                      await SettingsStore.setTitleFont(v);
                      if (mounted) setState(() => _titleFont = v);
                    }),
                    _fontRow('单号字号', _orderNoFont, (v) async {
                      if (v == null) return;
                      await SettingsStore.setOrderNoFont(v);
                      if (mounted) setState(() => _orderNoFont = v);
                    }),
                    _fontRow('正文字号', _bodyFont, (v) async {
                      if (v == null) return;
                      await SettingsStore.setBodyFont(v);
                      if (mounted) setState(() => _bodyFont = v);
                    }, four: false),
                    const SizedBox(height: 12),
                    // 标签文字（时间/菜品/数量/单价/小计/合计金额）
                    const Text('标签文字（留空恢复默认）',
                        style: TextStyle(fontSize: 13, color: Colors.grey)),
                    _labelRow(_timeLabelCtrl, '时间'),
                    _labelRow(_dishLabelCtrl, '菜品'),
                    _labelRow(_qtyLabelCtrl, '数量'),
                    _labelRow(_priceLabelCtrl, '单价'),
                    _labelRow(_subtotalLabelCtrl, '小计'),
                    _labelRow(_totalLabelCtrl, '合计金额'),
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton(
                          onPressed: _saveLabels, child: const Text('保存标签')),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // ===== 外卖单号设置 =====
            const Text('外卖单号', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('当前下一单号', style: TextStyle(fontSize: 16)),
                        Text(formatNo(_nextNo),
                            style: const TextStyle(
                                fontSize: 24, fontWeight: FontWeight.bold, color: Colors.blueGrey)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text('起始数字（保存后从该数字重新开始，如 1 → 001）',
                        style: TextStyle(fontSize: 13, color: Colors.grey)),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _startNoCtrl,
                            keyboardType: TextInputType.number,
                            style: const TextStyle(fontSize: 18),
                            decoration: const InputDecoration(labelText: '起始数字', hintText: '1'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: _saveStartNo,
                          child: const Text('保存', style: TextStyle(fontSize: 16)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            // ===== 标签管理（品类 / 口味）=====
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('标签管理',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                TextButton.icon(
                  onPressed: () => _tagEditor(),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('新建标签'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_tags.isEmpty)
                      const Text(
                        '还没有标签。先建「鸡架」这样的品类标签，再建「原味」「辣味」口味标签，'
                        '然后给下面的菜品选上。',
                        style: TextStyle(fontSize: 13, color: Colors.grey),
                      )
                    else ...[
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final t in _tags)
                            InputChip(
                              label: Text(t.isCat
                                  ? '${t.name}（品类）'
                                  : (t.isSpicy ? '${t.name} 🌶' : t.name)),
                              onPressed: () => _tagEditor(origin: t),
                              onDeleted: () => _deleteTag(t),
                              deleteIcon: const Icon(Icons.close, size: 16),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      const Text('点标签可改名 / 改类型，× 删除',
                          style: TextStyle(fontSize: 12, color: Colors.grey)),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            // ===== 桌号管理（堂食点单时下拉选择）=====
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('桌号管理',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                TextButton.icon(
                  onPressed: () => _tableNoEditor(),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('新增桌号'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_tableNos.isEmpty)
                      const Text(
                        '还没有桌号。新增后，新建订单选「堂食」时会出现在桌号下拉框里，'
                        '打印的小票顶部会显示「堂食(Table:桌号)」。',
                        style: TextStyle(fontSize: 13, color: Colors.grey),
                      )
                    else ...[
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final t in _tableNos)
                            InputChip(
                              label: Text('$t 号桌'),
                              onPressed: () => _tableNoEditor(origin: t),
                              onDeleted: () => _deleteTableNo(t),
                              deleteIcon: const Icon(Icons.close, size: 16),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      const Text('点桌号可改名 / 修改，× 删除',
                          style: TextStyle(fontSize: 12, color: Colors.grey)),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            // ===== 菜单管理 =====
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('菜单管理', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                Text('共 ${_menu.length} 项', style: const TextStyle(fontSize: 13, color: Colors.grey)),
              ],
            ),
            const SizedBox(height: 8),
            if (_menu.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('暂无菜单，请在下方添加菜品和价格',
                    style: TextStyle(color: Colors.grey)),
              )
            else
              ..._menu.asMap().entries.map((e) {
                final idx = e.key;
                final m = e.value;
                return Card(
                  margin: const EdgeInsets.only(bottom: 6),
                  child: ListTile(
                    title: Row(
                      children: [
                        if (SettingsStore.isSpicyFlavor(_tags, m.flavorTag))
                          const Padding(
                            padding: EdgeInsets.only(right: 6),
                            child: Text('🌶', style: TextStyle(fontSize: 16)),
                          ),
                        Expanded(
                          child: Text(m.name, style: const TextStyle(fontSize: 17)),
                        ),
                      ],
                    ),
                    subtitle: Text(
                      '${fmt(m.price)} $_currency${_menuTagLabel(m)}',
                      style: const TextStyle(fontSize: 13, color: Colors.grey),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.edit_outlined, color: Colors.blueGrey, size: 26),
                      tooltip: '编辑/删除',
                      onPressed: () => _editMenu(idx),
                    ),
                    onTap: () => _editMenu(idx),
                  ),
                );
              }),
            const SizedBox(height: 8),

            // 添加菜单
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  children: [
                    TextField(
                        controller: _nameCtrl,
                        style: const TextStyle(fontSize: 18),
                        decoration: const InputDecoration(labelText: '菜品名称')),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _priceCtrl,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            style: const TextStyle(fontSize: 18),
                            decoration: InputDecoration(labelText: '单价（$_currency）'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(minimumSize: const Size(72, 52)),
                          onPressed: _addMenu,
                          child: const Text('添加', style: TextStyle(fontSize: 18)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    _tagPickerTile(
                      label: '品类标签（用于合并统计）',
                      value: _addCatTag,
                      type: 'cat',
                      onPicked: (v) => setState(() => _addCatTag = v),
                    ),
                    _tagPickerTile(
                      label: '口味标签（用于区分辣/不辣）',
                      value: _addFlavorTag,
                      type: 'flavor',
                      onPicked: (v) => setState(() => _addFlavorTag = v),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // ===== 打印调试日志（排查打印失败）=====
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('打印调试日志',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                Row(children: [
                  TextButton(onPressed: _refreshLogs, child: const Text('刷新')),
                  TextButton(
                      onPressed: _clearLogs,
                      child: const Text('清空', style: TextStyle(color: Colors.red))),
                ]),
              ],
            ),
            const SizedBox(height: 4),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: _logs.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: Text('暂无日志。打印失败后再来这里查看',
                            style: TextStyle(color: Colors.grey, fontSize: 13)))
                    : ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 260),
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: _logs.length,
                          itemBuilder: (context, i) => Text(
                            _logs[i],
                            style: const TextStyle(fontSize: 12, height: 1.4),
                          ),
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
