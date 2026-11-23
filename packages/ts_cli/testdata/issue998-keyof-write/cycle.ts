function cycle<T extends U, U extends T>() {
  const key: keyof T = "missing";
  return key;
}

void cycle;
