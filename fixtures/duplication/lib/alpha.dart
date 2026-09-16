/// 이름만 다른 사본이다 — 토큰 구조는 beta.dart의 것과 같다.
int normalizeAlpha(int input, int limit) {
  if (input <= 0) {
    return 0;
  }
  var result = 0;
  for (var i = 0; i < input; i++) {
    result += i * 2;
    if (result > limit) {
      result = result - limit;
    }
  }
  while (result > 10) {
    result = result - 7;
  }
  return result;
}

int alphaUnique() => 1;
