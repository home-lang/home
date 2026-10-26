interface Alpha<T> { make(): Beta<T> }
interface Beta<T> { value: T }
declare const alpha: Alpha<number>;
const beta = alpha.make();
beta.value = 2;
const numeric: number = beta.value;
