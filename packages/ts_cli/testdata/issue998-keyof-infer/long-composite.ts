declare function take<T>(key: keyof T): T;
function long<T0 extends T1, T1 extends T2, T2 extends T3, T3 extends T4, T4 extends T5, T5 extends T6, T6 extends T7, T7 extends T8, T8 extends T9, T9 extends T10, T10 extends T11, T11 extends T12, T12 extends T13, T13 extends T14, T14 extends T15, T15 extends T16, T16 extends T17, T17 extends T18, T18 extends T19, T19 extends T20, T20 extends { present: number }, U extends { other: string }>(key: keyof (T0 & U)) {
  const result = take(key);
  const reveal: never = result;
  result.present;
  result.other;
  return reveal;
}
void long;
