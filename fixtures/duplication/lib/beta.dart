int normalizeBeta(int value, int cap) {
  if (value <= 0) {
    return 0;
  }
  var result = 0;
  for (var i = 0; i < value; i++) {
    result += i * 2;
    if (result > cap) {
      result = result - cap;
    }
  }
  while (result > 10) {
    result = result - 7;
  }
  return result;
}

int betaUnique() => 2;
