mixin Labelled {
  String get label => 'feature';
}

class MixedFeature with Labelled {}

extension Decoration on String {
  String get decorated => '[$this]';
}
