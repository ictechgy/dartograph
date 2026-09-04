part of 'model.dart';

User _$UserFromJson(Map<String, Object?> json) => User(json['name']! as String);

Map<String, Object?> _$UserToJson(User value) => {'name': value.name};
