pub fn toJS(this: ErrorResponse, globalObject: *jsc.JSGlobalObject) JSValue {
    var b = bun.StringBuilder{};
    defer b.deinit(bun.default_allocator);

    for (this.messages.items) |*msg| {
        b.cap += switch (msg.*) {
            inline else => |m| m.slice().len,
        } + 1;
    }
    b.allocate(bun.default_allocator) catch {};

    var severity: String = .{};
    var code: String = .{};
    var message: String = .{};
    var detail: String = .{};
    var hint: String = .{};
    var position: String = .{};
    var internalPosition: String = .{};
    var internal: String = .{};
    var where: String = .{};
    var schema: String = .{};
    var table: String = .{};
    var column: String = .{};
    var datatype: String = .{};
    var constraint: String = .{};
    var file: String = .{};
    var line: String = .{};
    var routine: String = .{};

    for (this.messages.items) |*msg| {
        switch (msg.*) {
            .severity => |str| severity = str,
            .code => |str| code = str,
            .message => |str| message = str,
            .detail => |str| detail = str,
            .hint => |str| hint = str,
            .position => |str| position = str,
            .internal_position => |str| internalPosition = str,
            .internal => |str| internal = str,
            .where => |str| where = str,
            .schema => |str| schema = str,
            .table => |str| table = str,
            .column => |str| column = str,
            .datatype => |str| datatype = str,
            .constraint => |str| constraint = str,
            .file => |str| file = str,
            .line => |str| line = str,
            .routine => |str| routine = str,
            else => {},
        }
    }

    var needs_newline = false;
    construct_message: {
        if (message.slice().len > 0) {
            _ = b.append(message.slice());
            needs_newline = true;
            break :construct_message;
        }
        if (detail.slice().len > 0) {
            if (needs_newline) {
                _ = b.append("\n");
            } else {
                _ = b.append(" ");
            }
            needs_newline = true;
            _ = b.append(detail.slice());
        }
        if (hint.slice().len > 0) {
            if (needs_newline) {
                _ = b.append("\n");
            } else {
                _ = b.append(" ");
            }
            needs_newline = true;
            _ = b.append(hint.slice());
        }
    }

    const errno = if (code.slice().len > 0) code.slice() else null;
    const error_code = if (std.mem.eql(u8, code.slice(), "42601")) // syntax error - https://www.postgresql.org/docs/8.1/errcodes-appendix.html
        "ERR_POSTGRES_SYNTAX_ERROR"
    else
        "ERR_POSTGRES_SERVER_ERROR";

    const detail_slice = if (detail.slice().len == 0) null else detail.slice();
    const hint_slice = if (hint.slice().len == 0) null else hint.slice();
    const severity_slice = if (severity.slice().len == 0) null else severity.slice();
    const position_slice = if (position.slice().len == 0) null else position.slice();
    const internalPosition_slice = if (internalPosition.slice().len == 0) null else internalPosition.slice();
    const internalQuery_slice = if (internal.slice().len == 0) null else internal.slice();
    const where_slice = if (where.slice().len == 0) null else where.slice();
    const schema_slice = if (schema.slice().len == 0) null else schema.slice();
    const table_slice = if (table.slice().len == 0) null else table.slice();
    const column_slice = if (column.slice().len == 0) null else column.slice();
    const dataType_slice = if (datatype.slice().len == 0) null else datatype.slice();
    const constraint_slice = if (constraint.slice().len == 0) null else constraint.slice();
    const file_slice = if (file.slice().len == 0) null else file.slice();
    const line_slice = if (line.slice().len == 0) null else line.slice();
    const routine_slice = if (routine.slice().len == 0) null else routine.slice();

    const error_message = if (b.len > 0) b.allocatedSlice()[0..b.len] else "";

    return createPostgresError(globalObject, error_message, .{
        .code = error_code,
        .errno = errno,
        .detail = detail_slice,
        .hint = hint_slice,
        .severity = severity_slice,
        .position = position_slice,
        .internalPosition = internalPosition_slice,
        .internalQuery = internalQuery_slice,
        .where = where_slice,
        .schema = schema_slice,
        .table = table_slice,
        .column = column_slice,
        .dataType = dataType_slice,
        .constraint = constraint_slice,
        .file = file_slice,
        .line = line_slice,
        .routine = routine_slice,
    }) catch |e| globalObject.takeError(e);
}

const ErrorResponse = @import("../../../sql/postgres/protocol/ErrorResponse.zig");
const String = @import("../../../sql/postgres/protocol/FieldMessage.zig").FieldMessage.String;
const createPostgresError = @import("../error_jsc.zig").createPostgresError;

const bun = @import("bun");
const std = @import("std");

const jsc = bun.jsc;
const JSValue = jsc.JSValue;
