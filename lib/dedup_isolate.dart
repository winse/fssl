import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'dedup_controller.dart';

/// isolate 启动数据
class _IsolateConfig {
  final SendPort mainSendPort;
  final SendPort responseSendPort;
  _IsolateConfig({required this.mainSendPort, required this.responseSendPort});
}

abstract class DedupRequest {
  int get id;
}

class DedupMessageRequest extends DedupRequest {
  final int id;
  final File duplicate;
  final File original;
  DedupMessageRequest(this.id, this.duplicate, this.original);
}

class DedupDoneRequest extends DedupRequest {
  final int id;
  DedupDoneRequest(this.id);
}

abstract class DedupResponse {
  int get id;
}

class DedupMessageResponse extends DedupResponse {
  final DedupMessageRequest _request;

  final bool success;
  final dynamic error;
  DedupMessageResponse(this._request, this.success, [this.error]);

  int get id => _request.id;
  File get duplicate => _request.duplicate;
  File get original => _request.original;
}

class DedupDoneResponse extends DedupResponse {
  final int id;
  DedupDoneResponse(this.id);
}

class DedupIsolateManager {
  late Isolate _isolate;
  late SendPort _sendPort;

  final _responsePort = ReceivePort();

  int _taskIdCounter = 0;
  final Map<int, Completer<DedupResponse>> _taskCompleters = {};

  DedupIsolateManager();

  Future<void> start() async {
    final readyPort = ReceivePort();
    _isolate = await Isolate.spawn<_IsolateConfig>(
      _isolateEntry,
      _IsolateConfig(mainSendPort: readyPort.sendPort, responseSendPort: _responsePort.sendPort),
    );

    // 等待 isolate 回传它的 sendPort
    _sendPort = await readyPort.first as SendPort;

    _responsePort.listen((message) {
      if (message is DedupDoneResponse) {
        this.dispose();
      }

      final int id = (message as DedupResponse).id;
      final completer = _taskCompleters.remove(id);
      if (completer != null && !completer.isCompleted) {
        completer.complete(message);
      }
    });
  }

  Future<DedupResponse> dedup(final File duplicate, final File original) {
    return _sendRequest(DedupMessageRequest(++_taskIdCounter, duplicate, original));
  }

  Future<DedupResponse> dedupDone() {
    return _sendRequest(DedupDoneRequest(++_taskIdCounter));
  }

  Future<DedupResponse> _sendRequest(DedupRequest request) async {
    final completer = Completer<DedupResponse>();
    _taskCompleters[request.id] = completer;

    _sendPort.send(request);

    return completer.future;
  }

  void dispose() {
    _isolate.kill(priority: Isolate.immediate);
    _responsePort.close();
  }
}

void _isolateEntry(_IsolateConfig config) async {
  final port = ReceivePort();

  final DedupController controller = DedupController();

  // 通知主 isolate：我准备好了，给你我的 SendPort
  config.mainSendPort.send(port.sendPort);

  await for (var msg in port) {
    if (msg is DedupMessageRequest) {
      try {
        final ok = controller.performDedup(msg.duplicate, msg.original);
        // 回传结果
        config.responseSendPort.send(DedupMessageResponse(msg, ok));
      } catch (e) {
        config.responseSendPort.send(DedupMessageResponse(msg, false, e));
      }
    } else if (msg is DedupDoneRequest) {
      config.responseSendPort.send(DedupDoneResponse(msg.id));
    }
  }
}
