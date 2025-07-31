import 'dart:async';
import 'dart:typed_data';
import 'ihub_protocol.dart';
import 'iconnection.dart';

/// @private
class MessageBuffer {
  final IHubProtocol _protocol;
  final IConnection _connection;

  final int _bufferSize;

  final List<BufferedItem> _messages = [];
  int _totalMessageCount = 0;
  bool _waitForSequenceMessage = false;

  // Message IDs start at 1 and always increment by 1
  int _nextReceivingSequenceId = 1;
  int _latestReceivedSequenceId = 0;
  int _bufferedByteCount = 0;
  bool _reconnectInProgress = false;

  Timer? _ackTimerHandle;

  MessageBuffer(this._protocol, this._connection, this._bufferSize);

  Future<void> send(HubMessageBase message) async {
    final serializedMessage = _protocol.writeMessage(message);

    Future<void> backpressureFuture = Future.value();

    if (_isInvocationMessage(message)) {
      _totalMessageCount++;

      final completer = Completer<void>();

      if (serializedMessage is Uint8List) {
        _bufferedByteCount += serializedMessage.length;
      } else if (serializedMessage is String) {
        _bufferedByteCount += serializedMessage.length;
      }

      if (_bufferedByteCount >= _bufferSize) {
        backpressureFuture = completer.future;
      }

      _messages.add(BufferedItem(
        serializedMessage,
        _totalMessageCount,
        completer,
      ));
    }

    try {
      if (!_reconnectInProgress) {
        await _connection.send(serializedMessage);
      }
    } catch (_) {
      disconnected();
    }

    await backpressureFuture;
  }

  void ack(AckMessage ackMessage) {
    int newestAckedMessage = -1;

    for (int index = 0; index < _messages.length; index++) {
      final element = _messages[index];
      if (element.id <= ackMessage.sequenceId) {
        newestAckedMessage = index;

        if (element.message is Uint8List) {
          _bufferedByteCount -= (element.message as Uint8List).length;
        } else if (element.message is String) {
          _bufferedByteCount -= (element.message as String).length;
        }

        element.resolver.complete();
      } else if (_bufferedByteCount < _bufferSize) {
        element.resolver.complete();
      } else {
        break;
      }
    }

    if (newestAckedMessage != -1) {
      _messages.removeRange(0, newestAckedMessage + 1);
    }
  }

  bool shouldProcessMessage(HubMessageBase message) {
    if (_waitForSequenceMessage) {
      if (message.type != MessageType.Sequence) {
        return false;
      } else {
        _waitForSequenceMessage = false;
        return true;
      }
    }

    if (!_isInvocationMessage(message)) {
      return true;
    }

    final currentId = _nextReceivingSequenceId;
    _nextReceivingSequenceId++;
    if (currentId <= _latestReceivedSequenceId) {
      if (currentId == _latestReceivedSequenceId) {
        _ackTimer();
      }
      return false; // duplicate
    }

    _latestReceivedSequenceId = currentId;
    _ackTimer();
    return true;
  }

  void resetSequence(SequenceMessage message) {
    if (message.sequenceId > _nextReceivingSequenceId) {
      _connection.stop(
        error: Exception("Sequence ID greater than amount of messages we've received."),
      );
      return;
    }
    _nextReceivingSequenceId = message.sequenceId;
  }

  void disconnected() {
    _reconnectInProgress = true;
    _waitForSequenceMessage = true;
  }

  Future<void> resend() async {
    final sequenceId = _messages.isNotEmpty ? _messages[0].id : _totalMessageCount + 1;
    await _connection.send(
      _protocol.writeMessage(SequenceMessage(sequenceId)),
    );

    final messagesSnapshot = List<BufferedItem>.from(_messages);
    for (final element in messagesSnapshot) {
      await _connection.send(element.message);
    }

    _reconnectInProgress = false;
  }

  void dispose([Exception? error]) {
    final err = error ?? Exception("Unable to reconnect to server.");

    for (final element in _messages) {
      if (!element.resolver.isCompleted) {
        element.resolver.completeError(err);
      }
    }
  }

  bool _isInvocationMessage(HubMessageBase message) {
    switch (message.type) {
      case MessageType.Invocation:
      case MessageType.StreamItem:
      case MessageType.Completion:
      case MessageType.StreamInvocation:
      case MessageType.CancelInvocation:
        return true;
      case MessageType.Close:
      case MessageType.Sequence:
      case MessageType.Ping:
      case MessageType.Ack:
        return false;
      default:
        return false;
    }
  }

  void _ackTimer() {
    if (_ackTimerHandle == null) {
      _ackTimerHandle = Timer(Duration(seconds: 1), () async {
        try {
          if (!_reconnectInProgress) {
            await _connection.send(
              _protocol.writeMessage(
                AckMessage(_latestReceivedSequenceId),
              ),
            );
          }
        } catch (_) {
          // ignore, connection closed
        }
        _ackTimerHandle?.cancel();
        _ackTimerHandle = null;
      });
    }
  }
}

class BufferedItem {
  final Object message;
  final int id;
  final Completer<void> resolver;

  BufferedItem(this.message, this.id, this.resolver);
}
