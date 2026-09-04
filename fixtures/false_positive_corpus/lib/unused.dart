void intentionallyDead() {}

class NotAnEntryPoint {
  void main() {}
}

const visibleForTesting = _FakeVisibleForTesting();

class _FakeVisibleForTesting {
  const _FakeVisibleForTesting();
}

@visibleForTesting
void falselyAnnotated() {}

@pragma('not-vm:entry-point')
void falsePragma() {}
