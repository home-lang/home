pub const MySQLRequestQueue = @This();

_requests: Queue,

_pipelined_requests: u32 = 0,
_nonpipelinable_requests: u32 = 0,
// TODO: refactor to ENUM
_waiting_to_prepare: bool = false,
_is_ready_for_query: bool = true,

pub inline fn canExecuteQuery(this: *const @This(), connection: *const MySQLConnection) bool {
    return connection.isAbleToWrite() and
        this._is_ready_for_query and
        this._nonpipelinable_requests == 0 and
        this._pipelined_requests == 0;
}
pub inline fn canPrepareQuery(this: *const @This(), connection: *const MySQLConnection) bool {
    return connection.isAbleToWrite() and
        this._is_ready_for_query and
        !this._waiting_to_prepare and
        this._pipelined_requests == 0;
}

pub inline fn markAsReadyForQuery(this: *@This()) void {
    this._is_ready_for_query = true;
}
pub inline fn markAsPrepared(this: *@This()) void {
    this._waiting_to_prepare = false;
    if (this.current()) |request| {
        debug("markAsPrepared markAsPrepared", .{});
        request.markAsPrepared();
    }
}
pub inline fn canPipeline(this: *@This(), connection: *MySQLConnection) bool {
    if (bun.feature_flag.BUN_FEATURE_FLAG_DISABLE_SQL_AUTO_PIPELINING.get()) {
        @branchHint(.unlikely);
        return false;
    }

    return this._is_ready_for_query and
        this._nonpipelinable_requests == 0 and // need to wait for non pipelinable requests to finish
        !this._waiting_to_prepare and
        connection.isAbleToWrite();
}

pub fn markCurrentRequestAsFinished(this: *@This(), item: *JSMySQLQuery) void {
    this._waiting_to_prepare = false;
    if (item.isBeingPrepared()) {
        debug("markCurrentRequestAsFinished markAsPrepared", .{});
        item.markAsPrepared();
    } else if (item.isRunning()) {
        if (item.isPipelined()) {
            this._pipelined_requests -= 1;
        } else {
            this._nonpipelinable_requests -= 1;
        }
    }
}

pub fn advance(this: *@This(), connection: *MySQLConnection) void {
    var offset: usize = 0;
    defer {
        while (this._requests.readableLength() > 0) {
            const request = this._requests.peekItem(0);
            // An item may be in the success or failed state and still be inside the queue (see deinit later comments)
            // so we do the cleanup her
            if (request.isCompleted()) {
                debug("isCompleted discard after advance", .{});
                this._requests.discard(1);
                request.deref();
                continue;
            }
            break;
        }
    }

    while (this._requests.readableLength() > offset and connection.isAbleToWrite()) {
        var request: *JSMySQLQuery = this._requests.peekItem(offset);

        if (request.isCompleted()) {
            if (offset > 0) {
                // discard later
                offset += 1;
                continue;
            }
            debug("isCompleted", .{});
            this._requests.discard(1);
            request.deref();
            continue;
        }

        if (request.isBeingPrepared()) {
            debug("isBeingPrepared", .{});
            this._waiting_to_prepare = true;
            // cannot continue the queue until the current request is marked as prepared
            return;
        }
        if (request.isRunning()) {
            debug("isRunning", .{});
            const total_requests_running = this._pipelined_requests + this._nonpipelinable_requests;
            if (offset < total_requests_running) {
                offset += total_requests_running;
            } else {
                offset += 1;
            }
            continue;
        }

        request.run(connection) catch |err| {
            debug("run failed", .{});
            connection.onError(request, err);
            // onError can re-entrantly drain the queue; only discard the head if
            // it's still there and still this request (else we drop the wrong
            // item / double-deref).
            if (offset == 0 and this._requests.readableLength() > 0 and this._requests.peekItem(0) == request) {
                this._requests.discard(1);
                request.deref();
            }
            offset += 1;
            continue;
        };
        if (request.isBeingPrepared()) {
            debug("isBeingPrepared", .{});
            connection.resetConnectionTimeout();
            this._is_ready_for_query = false;
            this._waiting_to_prepare = true;
            return;
        } else if (request.isRunning()) {
            connection.resetConnectionTimeout();
            debug("isRunning after run", .{});
            this._is_ready_for_query = false;

            if (request.isPipelined()) {
                this._pipelined_requests += 1;
                if (this.canPipeline(connection)) {
                    debug("pipelined requests", .{});
                    offset += 1;
                    continue;
                }
                return;
            }
            debug("nonpipelinable requests", .{});
            this._nonpipelinable_requests += 1;
        }
        return;
    }
}

pub fn init() @This() {
    return .{ ._requests = Queue.init(bun.default_allocator) };
}

pub fn isEmpty(this: *@This()) bool {
    return this._requests.readableLength() == 0;
}

pub fn add(this: *@This(), request: *JSMySQLQuery) void {
    debug("add", .{});
    if (request.isBeingPrepared()) {
        this._is_ready_for_query = false;
        this._waiting_to_prepare = true;
    } else if (request.isRunning()) {
        this._is_ready_for_query = false;

        if (request.isPipelined()) {
            this._pipelined_requests += 1;
        } else {
            this._nonpipelinable_requests += 1;
        }
    }
    request.ref();
    bun.handleOom(this._requests.writeItem(request));
}

pub inline fn current(this: *const @This()) ?*JSMySQLQuery {
    if (this._requests.readableLength() == 0) {
        return null;
    }

    return this._requests.peekItem(0);
}

pub fn clean(this: *@This(), reason: ?JSValue, queries_array: JSValue) void {
    // reject()/rejectWithJSValue() run JS which can synchronously call .close()
    // (or otherwise fail the connection) and re-enter clean(). Swap the queue
    // into a local first so the re-entrant call sees an empty queue instead of
    // deref()'ing + discard()'ing the same requests out from under us.
    var requests = this._requests;
    this._requests = Queue.init(bun.default_allocator);
    this._pipelined_requests = 0;
    this._nonpipelinable_requests = 0;
    this._waiting_to_prepare = false;
    defer requests.deinit();

    while (requests.readItem()) |request| {
        defer request.deref();
        if (request.isCompleted()) {
            continue;
        }
        if (reason) |r| {
            request.rejectWithJSValue(queries_array, r);
        } else {
            request.reject(queries_array, error.ConnectionClosed);
        }
    }
}

pub fn deinit(this: *@This()) void {
    for (this._requests.readableSlice(0)) |request| {
        this._requests.discard(1);
        // We cannot touch JS here
        request.markAsFailed();
        request.deref();
    }
    this._pipelined_requests = 0;
    this._nonpipelinable_requests = 0;
    this._waiting_to_prepare = false;
    this._requests.deinit();
}

const Queue = bun.LinearFifo(*JSMySQLQuery, .Dynamic);

const debug = bun.Output.scoped(.MySQLRequestQueue, .visible);

const JSMySQLQuery = @import("./JSMySQLQuery.zig");
const MySQLConnection = @import("./JSMySQLConnection.zig");
const bun = @import("bun");

const jsc = bun.jsc;
const JSValue = jsc.JSValue;
