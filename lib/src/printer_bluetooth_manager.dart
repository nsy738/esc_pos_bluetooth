/*
 * esc_pos_bluetooth
 * Created by Andrey Ushakov
 * 
 * Copyright (c) 2019-2020. All rights reserved.
 * See LICENSE for distribution and usage details.
 */

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:rxdart/rxdart.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_bluetooth_classic_serial/flutter_bluetooth_classic.dart' as serial;
import './enums.dart';
import 'package:async/async.dart';

/// 关键设计思路：
/// 1. flutter_blue_plus 只支持 BLE，API 与 flutter_bluetooth_basic 完全不同。
/// 2. 设备扫描、连接、数据发送都要用 flutter_blue_plus 的方式重写。
/// 3. BLE 打印机通常需要指定 Service UUID 和 Characteristic UUID，数据通过 writeCharacteristic 发送。
/// 4. 需维护设备扫描、连接、写入等状态流，兼容原有接口。
/// 5. 需兼容原有 PrinterBluetooth/PrinterBluetoothManager 的接口，便于上层调用不变。

/// Bluetooth printer 封装 BLE/SPP 设备
class PrinterBluetooth {
  // BLE
  PrinterBluetooth(this.device, {this.advData})
      : type = BluetoothType.ble,
        address = device?.remoteId.str,
        name = device?.platformName,
        serialDevice = null;
  // SPP
  PrinterBluetooth.spp(this.serialDevice)
      : type = BluetoothType.spp,
        address = serialDevice?.address,
        name = serialDevice?.name,
        device = null,
        advData = null;

  final BluetoothType type;
  final String? address;
  final String? name;
  // BLE
  final BluetoothDevice? device;
  final AdvertisementData? advData;
  // SPP
  final serial.BluetoothDevice? serialDevice;
}

/// BLE 打印机管理器
class PrinterBluetoothManager {
  // 维护扫描和连接状态
  bool _isPrinting = false;
  bool _isConnected = false;
  StreamSubscription? _scanResultsSubscription;
  PrinterBluetooth? _selectedPrinter;
  BluetoothCharacteristic? _writeChar;
  BluetoothDevice? _connectedDevice;
  // SPP相关
  final serial.FlutterBluetoothClassic _classic = serial.FlutterBluetoothClassic();
  final BehaviorSubject<bool> _isScanning = BehaviorSubject.seeded(false);
  Stream<bool> get isScanningStream => _isScanning.stream;
  final BehaviorSubject<List<PrinterBluetooth>> _scanResults =
      BehaviorSubject.seeded([]);
  Stream<List<PrinterBluetooth>> get scanResults => _scanResults.stream;
  // 需根据实际打印机填写 Service/Characteristic UUID
  // 可通过 nRF Connect 等工具扫描获得
  static const String printerServiceUUID = "0000ffe0-0000-1000-8000-00805f9b34fb";
  static const String printerCharUUID = "0000ffe1-0000-1000-8000-00805f9b34fb";
  // 新增：用于UI选择特征的回调
  void Function(List<Map<String, dynamic>>)? onWritableCharacteristicsDiscovered;
  StreamSubscription? _bleScanSub;
  StreamSubscription? _sppScanSub;

  Future _runDelayed(int seconds) {
    return Future<dynamic>.delayed(Duration(seconds: seconds));
  }

  /// 扫描蓝牙设备，可选BLE/SPP/Both
  void startScan(Duration timeout, {BluetoothType? type}) async {
    _scanResults.add(<PrinterBluetooth>[]);
    _isScanning.add(true);
    List<PrinterBluetooth> found = [];
    _scanResultsSubscription?.cancel();
    _bleScanSub?.cancel();
    _sppScanSub?.cancel();
    // BLE扫描
    if (type == null || type == BluetoothType.ble) {
      _bleScanSub = FlutterBluePlus.scanResults.listen((results) {
        found.addAll(results
            .map((r) => PrinterBluetooth(r.device, advData: r.advertisementData)));
        _scanResults.add(List<PrinterBluetooth>.from(found));
      });
      FlutterBluePlus.startScan(timeout: timeout);
    }
    // SPP扫描（只能获取已配对设备）
    if (type == null || type == BluetoothType.spp) {
      List<serial.BluetoothDevice> devices = await _classic.getPairedDevices();
      for (final device in devices) {
        found.add(PrinterBluetooth.spp(device));
      }
      _scanResults.add(List<PrinterBluetooth>.from(found));
    }
    // 超时后自动停止
    Future.delayed(timeout, () async {
      await stopScan();
    });
  }

  /// 停止扫描
  Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
    await _classic.stopDiscovery();
    _isScanning.add(false);
    await _scanResultsSubscription?.cancel();
    await _bleScanSub?.cancel();
    await _sppScanSub?.cancel();
  }

  /// 选择打印机
  void selectPrinter(PrinterBluetooth printer) {
    _selectedPrinter = printer;
  }

  /// 连接并写入数据（自动分流BLE/SPP）
  Future<PosPrintResult> writeBytes(
    List<int> bytes, {
    int chunkSizeBytes = 20,
    int queueSleepTimeMs = 20,
  }) async {
    if (_selectedPrinter == null) {
      return Future<PosPrintResult>.value(PosPrintResult.printerNotSelected);
    } else if (_isScanning.value!) {
      return Future<PosPrintResult>.value(PosPrintResult.scanInProgress);
    } else if (_isPrinting) {
      return Future<PosPrintResult>.value(PosPrintResult.printInProgress);
    }
    if (_selectedPrinter!.type == BluetoothType.ble) {
      return _writeBytesBle(bytes, chunkSizeBytes: chunkSizeBytes, queueSleepTimeMs: queueSleepTimeMs);
    } else {
      return _writeBytesSpp(bytes, chunkSizeBytes: chunkSizeBytes, queueSleepTimeMs: queueSleepTimeMs);
    }
  }

  /// BLE写入逻辑（原有实现）
  Future<PosPrintResult> _writeBytesBle(
    List<int> bytes, {
    int chunkSizeBytes = 20,
    int queueSleepTimeMs = 20,
  }) async {
    final Completer<PosPrintResult> completer = Completer();
    const int timeout = 10;
    if (_selectedPrinter == null) {
      return Future<PosPrintResult>.value(PosPrintResult.printerNotSelected);
    } else if (_isScanning.value!) {
      return Future<PosPrintResult>.value(PosPrintResult.scanInProgress);
    } else if (_isPrinting) {
      return Future<PosPrintResult>.value(PosPrintResult.printInProgress);
    }
    _isPrinting = true;
    final device = _selectedPrinter?.device;
    try {
      // 连接设备
      await device?.connect(timeout: Duration(seconds: 5));
      _connectedDevice = device;
      // 发现服务
      List<BluetoothService> services = await device?.discoverServices() ?? [];
      // 调试：打印所有服务和特征UUID及write属性
      for (var service in services) {
        print('[BLE] Service: [32m${service.uuid.str}[0m');
        for (var c in service.characteristics) {
          print('  [BLE] Characteristic: [36m${c.uuid.str}[0m, write: ${c.properties.write}');
        }
      }
      // 收集所有支持write的特征
      List<Map<String, dynamic>> writableChars = [];
      for (var service in services) {
        for (var c in service.characteristics) {
          if (c.properties.write) {
            writableChars.add({
              'service': service.uuid.str,
              'char': c.uuid.str,
              'charObj': c,
            });
          }
        }
      }
      // 如果有回调，交给UI选择
      if (onWritableCharacteristicsDiscovered != null && writableChars.isNotEmpty) {
        onWritableCharacteristicsDiscovered!(writableChars);
        // UI选择后会赋值writeChar
        // 这里直接return，等待UI回调
        _isPrinting = false;
        await device?.disconnect();
        return PosPrintResult.timeout;
      }
      // 自动选择第一个支持write的特征
      BluetoothCharacteristic? writeChar;
      if (writableChars.isNotEmpty) {
        writeChar = writableChars.first['charObj'];
        print('[BLE] Auto-selected first writable characteristic: service=${writableChars.first['service']}, char=${writableChars.first['char']}');
      } else {
        // 兼容：如果没找到，还是用UUID匹配
        for (var service in services) {
          if (service.uuid.str.toLowerCase() == printerServiceUUID) {
            for (var c in service.characteristics) {
              if (c.uuid.str.toLowerCase() == printerCharUUID && c.properties.write) {
                writeChar = c;
                break;
              }
            }
          }
        }
      }
      if (writeChar == null) {
        await device?.disconnect();
        _isPrinting = false;
        return PosPrintResult.timeout;
      }
      _writeChar = writeChar;
      // 分包写入
      final len = bytes.length;
      List<List<int>> chunks = [];
      for (var i = 0; i < len; i += chunkSizeBytes) {
        var end = (i + chunkSizeBytes < len) ? i + chunkSizeBytes : len;
        chunks.add(bytes.sublist(i, end));
      }
      for (var i = 0; i < chunks.length; i += 1) {
        await writeChar.write(chunks[i], withoutResponse: true);
        sleep(Duration(milliseconds: queueSleepTimeMs));
      }
      completer.complete(PosPrintResult.success);
      // 延迟断开
      _runDelayed(3).then((dynamic v) async {
        await device?.disconnect();
        _isPrinting = false;
      });
      _isConnected = true;
    } catch (e) {
      _isPrinting = false;
      try {
        await device?.disconnect();
      } catch (_) {}
      completer.complete(PosPrintResult.timeout);
    }
    // 打印超时
    _runDelayed(timeout).then((dynamic v) async {
      if (_isPrinting) {
        _isPrinting = false;
        try {
          await device?.disconnect();
        } catch (_) {}
        completer.complete(PosPrintResult.timeout);
      }
    });
    return completer.future;
  }

  /// SPP写入逻辑
  Future<PosPrintResult> _writeBytesSpp(
    List<int> bytes, {
    int chunkSizeBytes = 512,
    int queueSleepTimeMs = 20,
  }) async {
    final Completer<PosPrintResult> completer = Completer();
    final serial.BluetoothDevice? device = _selectedPrinter?.serialDevice;
    if (device == null) {
      return PosPrintResult.printerNotSelected;
    }
    try {
      _isPrinting = true;
      // 连接
      final connected = await _classic.connect(device.address);
      if (!connected) {
        _isPrinting = false;
        completer.complete(PosPrintResult.timeout);
        return completer.future;
      }
      // 分包写入
      final len = bytes.length;
      List<List<int>> chunks = [];
      for (var i = 0; i < len; i += chunkSizeBytes) {
        var end = (i + chunkSizeBytes < len) ? i + chunkSizeBytes : len;
        chunks.add(bytes.sublist(i, end));
      }
      for (var i = 0; i < chunks.length; i += 1) {
        await _classic.sendData(chunks[i]);
        sleep(Duration(milliseconds: queueSleepTimeMs));
      }
      await _classic.disconnect();
      completer.complete(PosPrintResult.success);
      _isConnected = true;
    } catch (e) {
      _isPrinting = false;
      try {
        await _classic.disconnect();
      } catch (_) {}
      completer.complete(PosPrintResult.timeout);
    }
    return completer.future;
  }

  /// 打印票据
  Future<PosPrintResult> printTicket(
    List<int> bytes, {
    int chunkSizeBytes = 20,
    int queueSleepTimeMs = 20,
  }) async {
    if (bytes.isEmpty) {
      return Future<PosPrintResult>.value(PosPrintResult.ticketEmpty);
    }
    return writeBytes(
      bytes,
      chunkSizeBytes: chunkSizeBytes,
      queueSleepTimeMs: queueSleepTimeMs,
    );
  }
}
