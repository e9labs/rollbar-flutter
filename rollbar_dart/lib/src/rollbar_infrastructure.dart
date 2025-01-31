import 'dart:core';
import 'dart:isolate';

import 'package:rollbar_common/rollbar_common.dart' as common;
import 'package:rollbar_dart/rollbar_dart.dart';

import '_internal/module.dart';
import 'http_sender.dart';

class RollbarInfrastructure {
  final ReceivePort _receivePort = ReceivePort();
  late final SendPort _sendPort;

  RollbarInfrastructure._() {
    Isolate.spawn(_processWorkItemsInBackground, _receivePort.sendPort,
        debugName: 'RollbarInfrastructureIsolate');
  }

  Future<SendPort> initialize({required Config rollbarConfig}) async {
    _sendPort = await _receivePort.first;
    ModuleLogger.moduleLogger.info('Send port: $_sendPort');
    _sendPort.send(rollbarConfig);
    return _sendPort;
  }

  Future<void> dispose() async {
    // Send a signal to the spawned isolate indicating that it should exit:
    _sendPort.send(null);
    _receivePort.close();
  }

  static final RollbarInfrastructure instance = RollbarInfrastructure._();

  void process({required PayloadRecord record}) {
    _sendPort.send(record);
  }

  static Future<void> _processWorkItemsInBackground(SendPort sendPort) async {
    ModuleLogger.moduleLogger.info('Infrastructure isolate started.');

    // Send a SendPort to the main isolate (RollbarInfrastructure)
    // so that it can send JSON strings to this isolate:
    final receivePort = ReceivePort();
    sendPort.send(receivePort.sendPort);

    // Wait for messages from the main isolate.
    await for (final message in receivePort) {
      bool continueProcessing = await _process(message);
      if (!continueProcessing) {
        break;
      }
    }

    ModuleLogger.moduleLogger.info('Infrastructure isolate finished.');
    Isolate.exit();
  }

  static Future<bool> _process(dynamic message) async {
    // HACK: This delay helps to avoid occasional sqlite's "db locked" errors/exceptions.
    // Keep it until we figure out why sqlite has these errors randomly:
    await Future.delayed(Duration(milliseconds: 25));

    if (message is Config) {
      _processConfig(message);
      await _processAllPendingRecords();
      return true;
    } else if (message is PayloadRecord) {
      await _processPayloadRecord(message);
      return true;
    } else if (message == null) {
      // Exit if the main isolate sends a null message, indicating
      // it is the time to exit.
      await _processAllPendingRecords();
      return false;
    } else {
      return true;
    }
  }

  static void _processConfig(Config config) {
    if (common.ServiceLocator.instance.registrationsCount == 0) {
      common.ServiceLocator.instance
          .register<PayloadRepository, PayloadRepository>(
              PayloadRepository.create(config.persistPayloads ?? false));
      common.ServiceLocator.instance.register<Sender, HttpSender>(HttpSender(
          endpoint: config.endpoint, accessToken: config.accessToken));
      common.ServiceLocator.instance
          .register<common.ConnectivityMonitor, ConnectivityMonitor>(
              ConnectivityMonitor());
    }
  }

  static Future<void> _processPayloadRecord(PayloadRecord payloadRecord) async {
    final repo = common.ServiceLocator.instance.tryResolve<PayloadRepository>();
    if (repo != null) {
      repo.addPayloadRecord(payloadRecord);
      await _processDestinationPendindRecords(payloadRecord.destination, repo);
    } else {
      ModuleLogger.moduleLogger
          .severe('PayloadRepository service was never registered!');
      await HttpSender(
              endpoint: payloadRecord.destination.endpoint,
              accessToken: payloadRecord.destination.accessToken)
          .sendString(payloadRecord.payloadJson);
      return; // we tried our best.
    }
  }

  static Future<void> _processDestinationPendindRecords(
      Destination destination, PayloadRepository repo) async {
    final records =
        await repo.getPayloadRecordsForDestinationAsync(destination);
    if (records.isEmpty) {
      return;
    }

    final sender = HttpSender(
        endpoint: destination.endpoint, accessToken: destination.accessToken);
    for (var record in records) {
      if (!await _processPendingRecord(record, sender, repo)) {
        break;
      }
    }
  }

  static Future<bool> _processPendingRecord(
      PayloadRecord record, Sender sender, PayloadRepository repo) async {
    final connectivityMonitor =
        common.ServiceLocator.instance.tryResolve<common.ConnectivityMonitor>();
    if (connectivityMonitor != null &&
        !connectivityMonitor.connectivityState.connectivityOn) {
      return false;
    }

    final success = await sender.sendString(record.payloadJson);
    if (success) {
      repo.removePayloadRecord(record);
      return true;
    } else {
      if (connectivityMonitor != null &&
          connectivityMonitor.connectivityState.connectivityOn) {
        connectivityMonitor.overrideAsOffFor(duration: Duration(seconds: 30));
      }
      final cutoffTime =
          DateTime.now().toUtc().subtract(const Duration(days: 1));
      if (record.timestamp.compareTo(cutoffTime) < 0) {
        repo.removePayloadRecord(record);
      }
      return false;
    }
  }

  static Future<void> _processAllPendingRecords() async {
    final repo = common.ServiceLocator.instance.tryResolve<PayloadRepository>();
    if (repo == null) {
      ModuleLogger.moduleLogger
          .severe('PayloadRepository service was never registered!');
    } else {
      final destinations = repo.getDestinations();
      for (final destination in destinations) {
        await _processDestinationPendindRecords(destination, repo);
      }
      await repo.removeUnusedDestinationsAsync();
    }
  }
}
