library;

import 'base.dart';

part 'model.g.dart';
part 'unnamed.dart';

class Service extends Base with Trait implements Contract {
  @override
  void work() {
    helper();
    value;
  }
}

class PublicApi {
  void call() => _privateCall();

  void _privateCall() {}
}

void helper() {}
var value = Service();

void invoke() {
  value.work();
}

Service echo(Service input) => input;

void update() {
  value = Service();
}
