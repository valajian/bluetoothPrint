# -*- coding: utf-8 -*-
"""
精臣 B3 打印机 USB 串口测试脚本
================================
用途：绕开蓝牙，用 USB 线直连打印机，验证三件事：
  1. 打印机硬件/固件是否正常（能否出纸）
  2. TSPL 指令格式是否正确（英文/中文/完整小票）
  3. 中文字体 "2" 与 "TSS24.BF2" 哪个可用

用法：
  1. USB 线连接打印机和电脑（先安装 USB-Driver-Install-1.0.3.0 里的驱动）
  2. 运行: python usb_print_test.py
  3. 按提示选择端口，依次出 4 张测试纸
  4. 把每张纸的结果告诉我（正常 / 空白 / 乱码 / 无反应）
"""
import sys
import time

import serial
import serial.tools.list_ports


def list_ports():
    ports = serial.tools.list_ports.comports()
    if not ports:
        print("未发现任何串口！请检查：")
        print("  1. USB 线已连接打印机和电脑")
        print("  2. 已安装驱动 USB-Driver-Installer-1.0.3.0.exe")
        print("  3. 设备管理器里能看到 COM 端口")
        sys.exit(1)
    print("发现以下串口：")
    for i, p in enumerate(ports):
        print("  [{}] {}  {}  {}".format(i, p.device, p.description, p.hwid))
    idx = int(input("选择端口编号: "))
    return ports[idx].device


def send(s, data, label):
    print("\n>>> 发送: {}".format(label))
    s.write(data)
    s.flush()
    time.sleep(2)  # 等待打印机处理/出纸


def main():
    port = list_ports()
    baud = 115200
    try:
        s = serial.Serial(port, baud, timeout=2)
    except Exception as e:
        print("打开 {} 失败: {}".format(port, e))
        sys.exit(1)
    print("已打开 {} @ {}，请确认打印机电源已打开、纸已装好".format(port, baud))
    input("按回车开始测试...")

    # A. 纯英文基础测试：验证打印机响应 TSPL
    a = ("SIZE 50 mm,0 mm\r\nGAP 0 mm,0 mm\r\nCLS\r\n"
         "TEXT 10,10,\"2\",0,1,1,\"HELLO TEST 123\"\r\nPRINT 1\r\n")
    send(s, a.encode("ascii"), "A. 基础英文（应打出 HELLO TEST 123）")

    # B. 中文 + 数字字体 "2"：若空白，说明 "2" 字体不含中文
    b = ("SIZE 50 mm,0 mm\r\nGAP 0 mm,0 mm\r\nCLS\r\n"
         "TEXT 10,10,\"2\",0,1,1,\"中文测试一二三\"\r\nPRINT 1\r\n")
    send(s, b.encode("GBK"), "B. 中文（字体 \"2\"，空白则说明无中文字形）")

    # C. 中文 + TSS24.BF2 字库字体：TSC 标准简体中文 24 点阵
    c = ("SIZE 50 mm,0 mm\r\nGAP 0 mm,0 mm\r\nCLS\r\n"
         "TEXT 10,10,\"TSS24.BF2\",0,1,1,\"中文测试四五六\"\r\nPRINT 1\r\n")
    send(s, c.encode("GBK"), "C. 中文（字体 \"TSS24.BF2\"）")

    # D. 完整小票：与 APP buildTSPL 完全一致的指令
    d = ("SIZE 50 mm,0 mm\r\nGAP 0 mm,0 mm\r\nOFFSET 0 mm\r\nSET TEAR ON\r\nCLS\r\n"
         "TEXT 10,10,\"2\",0,1,1,\"*** 美味小摊 ***\"\r\n"
         "BAR 10,50,200,2,\"-\"\r\n"
         "TEXT 10,70,\"2\",0,1,1,\"外卖单号：001\"\r\n"
         "TEXT 10,100,\"2\",0,1,1,\"时间：08-20 19:00\"\r\n"
         "BAR 10,130,200,1,\"-\"\r\n"
         "TEXT 10,150,\"2\",0,1,1,\"菜品          数量  单价  小计\"\r\n"
         "BAR 10,180,200,1,\"-\"\r\n"
         "TEXT 10,210,\"2\",0,1,1,\"烤肠        2  3.50  7.00\"\r\n"
         "BAR 10,250,200,2,\"-\"\r\n"
         "TEXT 10,280,\"2\",0,1,1,\"合计金额：7.00 元\"\r\n"
         "PRINT 1\r\n")
    send(s, d.encode("GBK"), "D. 完整小票（与 APP 相同指令）")

    s.close()
    print("\n测试完成！请记录每张纸的结果：正常 / 空白 / 乱码 / 无反应")


if __name__ == "__main__":
    main()
