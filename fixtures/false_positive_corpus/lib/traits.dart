mixin Labelled {
  String get label => 'feature';
}

class MixedFeature with Labelled {}

extension Decoration on String {
  String get decorated => '[$this]';
}

// dartograph:ignore
void keptByIgnoreComment() {}

// 같은 줄 꼬리 주석은 다음 선언의 억제가 아니다 — 계속 보고돼야 한다.
void trailingNotIgnored() {} // dartograph:ignore
