function parameterObject({ a }: { a: string | number }) {
  if (typeof a === "string") {
    const value: string = a;
    a.toUpperCase();
  }
}

function parameterArray([b]: [string | number]) {
  if (typeof b === "string") {
    const value: string = b;
    b.toUpperCase();
  }
}

function localObject(source: { a: string | number }) {
  let { a } = source;
  if (typeof a === "string") {
    const value: string = a;
    a.toUpperCase();
  }
}

function localArray(source: [string | number]) {
  const [b] = source;
  if (typeof b === "string") {
    const value: string = b;
    b.toUpperCase();
  }
}

function assignmentInvalidates(source: { a: string | number }) {
  let { a } = source;
  if (typeof a === "string") {
    const before: string = a;
    a = 1;
    const after: number = a;
    a.toFixed();
  }
}

function innerPatternShadows(source: { a: string | number }) {
  let { a } = source;
  if (typeof a === "string") {
    {
      let { a } = { a: 3 as string | number };
      if (typeof a === "number") {
        const inner: number = a;
        a.toFixed();
      }
    }
    const outer: string = a;
    a.toUpperCase();
  }
}
