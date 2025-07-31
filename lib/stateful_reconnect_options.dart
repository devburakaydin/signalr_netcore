/// Options provided to configure Stateful Reconnect.
class StatefulReconnectOptions {
  /// Amount of bytes we'll buffer when using Stateful Reconnect
  /// until applying backpressure to sends from the client.
  final int bufferSize;

  const StatefulReconnectOptions({required this.bufferSize});
}