type ActionType<P> = string;
declare const action: ActionType<void>;
type Handler<S, P> = P extends void ? (state: S) => S : (state: S, payload: P) => S;
interface ActionHandler<S, P> { actionType: ActionType<P>; handler: Handler<S, P>; }
declare function handler<S, P>(action: ActionType<P>, fn: Handler<S, P>): ActionHandler<S, P>;
declare function reducer<S>(state: S, ...handlers: ActionHandler<S, any>[]): S;
reducer({ dummy: '' }, handler(action, state => state));
export {};
