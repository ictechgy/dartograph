/// main에서도 호출되는 프로덕션 선언(테스트 전용이 아님).
void reachedByMain() {}

/// 테스트에서만 호출되는 프로덕션 선언.
void onlyReachedByTest() {}

/// 어디서도 호출되지 않는 선언(일반 dead, 테스트 전용 아님).
void deadEverywhere() {}
