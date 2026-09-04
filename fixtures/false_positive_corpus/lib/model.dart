part 'model.g.dart';
part 'model.freezed.dart';

class User {
  const User(this.name);

  factory User.fromJson(Map<String, Object?> json) => _$UserFromJson(json);

  final String name;

  Map<String, Object?> toJson() => _$UserToJson(this);
}
