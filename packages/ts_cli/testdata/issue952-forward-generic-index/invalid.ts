interface Alpha<T> { make(): Beta<T> }
interface Beta<T> extends Alpha<T> { value: T }
declare const alpha: Alpha<string>;
const beta = alpha.make();
beta.value = 2;
