function f() {
  let [x2 = x2] = [];
  let { p = p } = {} as { p?: number };
  for (let [loop = loop] of [[]] as number[][]) {}
  for (const {value = value} of [{}] as Array<{value?: number}>) {}
}
export {};
