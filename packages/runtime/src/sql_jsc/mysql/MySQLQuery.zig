const MySQLQuery = @This();

_statement: ?*MySQLStatement = null,
_query: bun.String,

_status: Status,
_flags: packed struct(u8) {
    bigint: bool = false,
    simple: bool = false,
    pipelined: bool = false,
    result_mode: SQLQueryResultMode = .objects,
    _padding: u3 = 0,
},

fn bind(this: *MySQLQuery, execute: *PreparedStatement.Execute, globalObject: *JSGlobalObject, binding_value: JSValue, columns_value: JSValue, roots: *bun.jsc.MarkedArgumentBuffer) AnyMySQLError.Error!void {
    var iter = try QueryBindingIterator.init(binding_value, columns_value, globalObject);

    var i: u32 = 0;
    var params = try bun.default_allocator.alloc(Value, execute.param_types.len);
    errdefer {
        for (params[0..i]) |*param| {
            param.deinit(bun.default_allocator);
        }
        bun.default_allocator.free(params);
    }
    while (try iter.next()) |js_value| {
        if (i >= params.len) {
            // The binding array yielded more values than the prepared statement
            // expects. This can happen when the user-supplied array is mutated (e.g.
            // from an index getter) between signature generation and binding. Fail
            // loudly instead of writing past the end of `params`/`param_types`.
            return error.WrongNumberOfParametersProvided;
        }
        const param = execute.param_types[i];
        params[i] = try Value.fromJS(
            js_value,
            globalObject,
            param.type,
            param.flags.UNSIGNED,
            roots,
        );
        i += 1;
    }

    if (iter.anyFailed()) {
        return error.InvalidQueryBinding;
    }

    if (i != params.len) {
        // Fewer values than the prepared statement expects; the remaining slots
        // would be uninitialized.
        return error.WrongNumberOfParametersProvided;
    }

    this._status = .binding;
    execute.params = params;
}

fn bindAndExecute(this: *MySQLQuery, writer: anytype, statement: *MySQLStatement, globalObject: *JSGlobalObject, binding_value: JSValue, columns_value: JSValue) AnyMySQLError.Error!void {
    bun.assertf(statement.params.len == statement.params_received and statement.statement_id > 0, "statement is not prepared", .{});
    if (statement.signature.fields.len != statement.params.len) {
        return error.WrongNumberOfParametersProvided;
    }

    // BLOB parameters borrow ArrayBuffer/Blob bytes rather than copying.
    // Converting later parameters can run user JS (index getters, toJSON,
    // toString coercion) which could drop the last reference to an earlier
    // buffer and force GC. Root every borrowed JSValue in a stack-scoped
    // MarkedArgumentBuffer so the wrapper (and its RefPtr<ArrayBuffer>)
    // survives until execute.deinit() has unpinned and released the borrow.
    const Ctx = struct {
        this: *MySQLQuery,
        writer: @TypeOf(writer),
        statement: *MySQLStatement,
        globalObject: *JSGlobalObject,
        binding_value: JSValue,
        columns_value: JSValue,
        result: AnyMySQLError.Error!void,

        pub fn run(ctx: *@This(), roots: *bun.jsc.MarkedArgumentBuffer) callconv(.c) void {
            ctx.result = bindAndExecuteImpl(ctx.this, ctx.writer, ctx.statement, ctx.globalObject, ctx.binding_value, ctx.columns_value, roots);
        }
    };
    var ctx: Ctx = .{
        .this = this,
        .writer = writer,
        .statement = statement,
        .globalObject = globalObject,
        .binding_value = binding_value,
        .columns_value = columns_value,
        .result = {},
    };
    bun.jsc.MarkedArgumentBuffer.run(Ctx, &ctx, &Ctx.run);
    return ctx.result;
}

fn bindAndExecuteImpl(this: *MySQLQuery, writer: anytype, statement: *MySQLStatement, globalObject: *JSGlobalObject, binding_value: JSValue, columns_value: JSValue, roots: *bun.jsc.MarkedArgumentBuffer) AnyMySQLError.Error!void {
    var execute = PreparedStatement.Execute{
        .statement_id = statement.statement_id,
        .param_types = statement.signature.fields,
        .new_params_bind_flag = statement.execution_flags.need_to_send_params,
        .iteration_count = 1,
    };
    defer execute.deinit();
    // Bind before touching the writer so a bind failure (user-triggerable via JS
    // getters / param-count mismatch) doesn't leave a partial packet header in
    // the connection's write buffer.
    try this.bind(&execute, globalObject, binding_value, columns_value, roots);
    var packet = try writer.start(0);
    try execute.write(writer);
    try packet.end();
    statement.execution_flags.need_to_send_params = false;
    this._status = .running;
}

fn runSimpleQuery(this: *@This(), connection: *MySQLConnection) !void {
    if (this._status != .pending or !connection.canExecuteQuery()) {
        debug("cannot execute query", .{});
        // cannot execute query
        return;
    }
    var query_str = this._query.toUTF8(bun.default_allocator);
    defer query_str.deinit();
    const writer = connection.getWriter();
    if (this._statement == null) {
        const stmt = bun.new(MySQLStatement, .{
            .signature = Signature.empty(),
            .status = .parsing,
            .ref_count = .initExactRefs(1),
        });
        this._statement = stmt;
    }
    try MySQLRequest.executeQuery(query_str.slice(), MySQLConnection.Writer, writer);

    this._status = .running;
}

fn runPreparedQuery(
    this: *@This(),
    connection: *MySQLConnection,
    globalObject: *JSGlobalObject,
    columns_value: JSValue,
    binding_value: JSValue,
) !void {
    var query_str: ?bun.ZigString.Slice = null;
    defer if (query_str) |str| str.deinit();

    if (this._statement == null) {
        const query = this._query.toUTF8(bun.default_allocator);
        query_str = query;
        var signature = Signature.generate(globalObject, query.slice(), binding_value, columns_value) catch |err| {
            if (!globalObject.hasException())
                return globalObject.throwValue(AnyMySQLError.mysqlErrorToJS(globalObject, "failed to generate signature", err));
            return error.JSError;
        };
        errdefer signature.deinit();
        const entry = connection.getStatementFromSignatureName(signature.name) catch |err| {
            return globalObject.throwError(err, "failed to allocate statement");
        };

        if (entry.found_existing) {
            const stmt = entry.value_ptr.*;
            if (stmt.status == .failed) {
                const error_response = stmt.error_response.toJS(globalObject);
                // If the statement failed, we need to throw the error
                return globalObject.throwValue(error_response);
            }
            this._statement = stmt;
            stmt.ref();
            signature.deinit();
            signature = Signature{};
        } else {
            const stmt = bun.new(MySQLStatement, .{
                .signature = signature,
                .ref_count = .initExactRefs(2),
                .status = .pending,
                .statement_id = 0,
            });
            this._statement = stmt;
            entry.value_ptr.* = stmt;
        }
    }
    const stmt = this._statement.?;
    switch (stmt.status) {
        .failed => {
            debug("failed", .{});
            const error_response = stmt.error_response.toJS(globalObject);
            // If the statement failed, we need to throw the error
            return globalObject.throwValue(error_response);
        },
        .prepared => {
            if (connection.canPipeline()) {
                debug("bindAndExecute", .{});
                const writer = connection.getWriter();
                this.bindAndExecute(writer, stmt, globalObject, binding_value, columns_value) catch |err| {
                    if (!globalObject.hasException())
                        return globalObject.throwValue(AnyMySQLError.mysqlErrorToJS(globalObject, "failed to bind and execute query", err));
                    return error.JSError;
                };
                this._flags.pipelined = true;
            }
        },
        .parsing => {
            debug("parsing", .{});
        },
        .pending => {
            if (connection.canPrepareQuery()) {
                debug("prepareRequest", .{});
                const writer = connection.getWriter();
                const query = query_str orelse this._query.toUTF8(bun.default_allocator);
                MySQLRequest.prepareRequest(query.slice(), MySQLConnection.Writer, writer) catch |err| {
                    return globalObject.throwError(err, "failed to prepare query");
                };
                stmt.status = .parsing;
            }
        },
    }
}

/// Takes ownership of `query` (caller must have already ref'd it, e.g. via
/// `JSValue.toBunString`). `cleanup()` will deref it exactly once.
pub fn init(query: bun.String, bigint: bool, simple: bool) @This() {
    return .{
        ._query = query,
        ._status = .pending,
        ._flags = .{
            .bigint = bigint,
            .simple = simple,
        },
    };
}

pub fn runQuery(this: *@This(), connection: *MySQLConnection, globalObject: *JSGlobalObject, columns_value: JSValue, binding_value: JSValue) !void {
    if (this._flags.simple) {
        debug("runSimpleQuery", .{});
        return try this.runSimpleQuery(connection);
    }
    debug("runPreparedQuery", .{});
    return try this.runPreparedQuery(
        connection,
        globalObject,
        if (columns_value == .zero) .js_undefined else columns_value,
        if (binding_value == .zero) .js_undefined else binding_value,
    );
}

pub inline fn setResultMode(this: *@This(), result_mode: SQLQueryResultMode) void {
    this._flags.result_mode = result_mode;
}

pub inline fn result(this: *@This(), is_last_result: bool) bool {
    if (this._status == .success or this._status == .fail) return false;
    this._status = if (is_last_result) .success else .partial_response;

    return true;
}
pub fn fail(this: *@This()) bool {
    if (this._status == .fail or this._status == .success) return false;
    this._status = .fail;

    return true;
}

pub fn cleanup(this: *@This()) void {
    if (this._statement) |statement| {
        statement.deref();
        this._statement = null;
    }
    var query = this._query;
    defer query.deref();
    this._query = bun.String.empty;
}

pub inline fn isCompleted(this: *const @This()) bool {
    return this._status == .success or this._status == .fail;
}
pub inline fn isRunning(this: *const @This()) bool {
    switch (this._status) {
        .running, .binding, .partial_response => return true,
        .success, .fail, .pending => return false,
    }
}
pub inline fn isPending(this: *const @This()) bool {
    return this._status == .pending;
}

pub inline fn isBeingPrepared(this: *@This()) bool {
    return this._status == .pending and this._statement != null and this._statement.?.status == .parsing;
}

pub inline fn isPipelined(this: *const @This()) bool {
    return this._flags.pipelined;
}
pub inline fn isSimple(this: *const @This()) bool {
    return this._flags.simple;
}
pub inline fn isBigintSupported(this: *const @This()) bool {
    return this._flags.bigint;
}
pub inline fn getResultMode(this: *const @This()) SQLQueryResultMode {
    return this._flags.result_mode;
}
pub inline fn markAsPrepared(this: *@This()) void {
    if (this._status == .pending) {
        if (this._statement) |statement| {
            if (statement.status == .parsing and
                statement.params.len == statement.params_received and
                statement.statement_id > 0)
            {
                statement.status = .prepared;
            }
        }
    }
}
pub inline fn getStatement(this: *const @This()) ?*MySQLStatement {
    return this._statement;
}

const debug = bun.Output.scoped(.MySQLQuery, .visible);

const AnyMySQLError = @import("../../sql/mysql/protocol/AnyMySQLError.zig");
const MySQLConnection = @import("./JSMySQLConnection.zig");
const MySQLRequest = @import("../../sql/mysql/MySQLRequest.zig");
const MySQLStatement = @import("./MySQLStatement.zig");
const PreparedStatement = @import("../../sql/mysql/protocol/PreparedStatement.zig");
const Signature = @import("./protocol/Signature.zig");
const bun = @import("bun");
const QueryBindingIterator = @import("../shared/QueryBindingIterator.zig").QueryBindingIterator;
const SQLQueryResultMode = @import("../../sql/shared/SQLQueryResultMode.zig").SQLQueryResultMode;
const Status = @import("../../sql/mysql/QueryStatus.zig").Status;
const Value = @import("../../sql/mysql/MySQLTypes.zig").Value;

const JSGlobalObject = bun.jsc.JSGlobalObject;
const JSValue = bun.jsc.JSValue;
