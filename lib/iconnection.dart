import 'dart:async';

import "itransport.dart";

class ConnectionFeatures {
  // Properties
  bool? inherentKeepAlive;
  bool reconnect;

  // Callback'ler
  Future<void> Function()? resend;
  void Function()? disconnected;

  // Constructor
  ConnectionFeatures(this.inherentKeepAlive, {this.reconnect = false, this.resend, this.disconnected});
}

abstract class IConnection {
  ConnectionFeatures? features;
  String? connectionId;

  String? baseUrl;

  Future<void> start({TransferFormat? transferFormat});

  Future<void> send(Object? data);

  Future<void>? stop({Exception? error});

  OnReceive? onreceive;
  OnClose? onclose;

  IConnection() : features = ConnectionFeatures(null);
}
