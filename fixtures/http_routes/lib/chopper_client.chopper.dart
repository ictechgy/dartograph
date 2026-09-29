// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format width=80

part of 'chopper_client.dart';

// **************************************************************************
// ChopperGenerator
// **************************************************************************

// coverage:ignore-file
// ignore_for_file: type=lint
final class _$TodoService extends TodoService {
  _$TodoService([ChopperClient? client]) {
    if (client == null) return;
    this.client = client;
  }

  @override
  final Type definitionType = TodoService;

  @override
  Future<Response<String>> list() {
    final Uri $url = Uri.parse('/todos');
    final Request $request = Request('GET', $url, client.baseUrl);
    return client.send<String, String>($request);
  }

  @override
  Future<Response<String>> item(String id) {
    final Uri $url = Uri.parse('/todos/${id}');
    final Request $request = Request('GET', $url, client.baseUrl);
    return client.send<String, String>($request);
  }

  @override
  Future<Response<String>> done() {
    final Uri $url = Uri.parse('/todos/done');
    final Request $request = Request('POST', $url, client.baseUrl);
    return client.send<String, String>($request);
  }
}

// coverage:ignore-file
// ignore_for_file: type=lint
final class _$AbsoluteChopperService extends AbsoluteChopperService {
  _$AbsoluteChopperService([ChopperClient? client]) {
    if (client == null) return;
    this.client = client;
  }

  @override
  final Type definitionType = AbsoluteChopperService;

  @override
  Future<Response<String>> ping() {
    final Uri $url = Uri.parse('http://api.example.test/ch/ping');
    final Request $request = Request('GET', $url, client.baseUrl);
    return client.send<String, String>($request);
  }
}

// coverage:ignore-file
// ignore_for_file: type=lint
final class _$BareChopperService extends BareChopperService {
  _$BareChopperService([ChopperClient? client]) {
    if (client == null) return;
    this.client = client;
  }

  @override
  final Type definitionType = BareChopperService;

  @override
  Future<Response<String>> remove(String id) {
    final Uri $url = Uri.parse('items/${id}');
    final Request $request = Request('DELETE', $url, client.baseUrl);
    return client.send<String, String>($request);
  }
}
